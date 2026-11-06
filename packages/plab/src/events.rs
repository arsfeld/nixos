//! Live updates for the app: one broadcast of `Event`s, served to each browser as SSE at
//! /api/events. Handlers publish through `WebState.events`; jobs that run without a
//! `WebState` (refresh) publish through the process-wide sender `serve` sets. There is no
//! replay: a client that reconnects, or lags and gets `resync`, refetches its view.

use crate::api::{JobDto, StatusDto};
use crate::backends::Backends;
use axum::body::Body;
use axum::http::Response;
use axum::response::IntoResponse;
use axum::response::sse::{Event as SseEvent, KeepAlive, Sse};
use futures::StreamExt;
use serde::Serialize;
use std::collections::HashMap;
use std::convert::Infallible;
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::Duration;
use tokio::sync::broadcast::{self, error::RecvError};

use crate::web::{self, WebState};

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    /// "" | "queued" | "added", after an add, an unqueue, or the queue drain.
    TopicState {
        id: u64,
        state: &'static str,
    },
    /// The status diff saw this topic's download status change; None: it has none now.
    TopicStatus {
        id: u64,
        status: Option<StatusDto>,
    },
    Job(JobDto),
    /// refresh wrote a new list for the section.
    Listing {
        section: &'static str,
    },
    /// A daily picks generation ended (picks or an error): refetch /api/assistant/daily.
    AssistantDaily,
    /// The client fell behind: refetch.
    Resync,
}

#[derive(Clone)]
pub struct Events(broadcast::Sender<Event>);

impl Default for Events {
    fn default() -> Self {
        Events::with_capacity(256)
    }
}

impl Events {
    pub fn with_capacity(n: usize) -> Self {
        Events(broadcast::channel(n).0)
    }

    /// Send to every connected client; nobody listening is not an error.
    pub fn publish(&self, e: Event) {
        let _ = self.0.send(e);
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.0.subscribe()
    }

    pub fn clients(&self) -> usize {
        self.0.receiver_count()
    }
}

static GLOBAL: OnceLock<Events> = OnceLock::new();

/// `serve` sets this to the sender its `WebState` holds.
pub fn set_global(e: Events) {
    let _ = GLOBAL.set(e);
}

/// Publish from code that has no `WebState`; a no-op in one-shot commands and tests.
pub fn publish(e: Event) {
    if let Some(g) = GLOBAL.get() {
        g.publish(e);
    }
}

/// A client's events: a lag becomes one `Resync`, then it carries on from the newest.
pub fn stream(rx: broadcast::Receiver<Event>) -> impl futures::Stream<Item = Event> {
    futures::stream::unfold(rx, |mut rx| async move {
        let e = match rx.recv().await {
            Ok(e) => e,
            Err(RecvError::Lagged(_)) => Event::Resync,
            Err(RecvError::Closed) => return None,
        };
        Some((e, rx))
    })
}

/// GET /api/events.
pub fn sse(events: &Events) -> Response<Body> {
    let s = stream(events.subscribe()).map(|e| {
        Ok::<_, Infallible>(
            SseEvent::default().data(serde_json::to_string(&e).expect("event json")),
        )
    });
    Sse::new(s)
        .keep_alive(
            KeepAlive::new()
                .interval(Duration::from_secs(15))
                .text("keep-alive"),
        )
        .into_response()
}

/// A `TopicStatus` for each topic whose status differs between the two samples, by id.
pub fn status_changes(prev: &HashMap<u64, StatusDto>, cur: &HashMap<u64, StatusDto>) -> Vec<Event> {
    let mut ids: Vec<u64> = prev.keys().chain(cur.keys()).copied().collect();
    ids.sort_unstable();
    ids.dedup();
    ids.into_iter()
        .filter(|id| prev.get(id) != cur.get(id))
        .map(|id| Event::TopicStatus {
            id,
            status: cur.get(&id).cloned(),
        })
        .collect()
}

/// How often the pump wakes; jobs are sampled on every wake (at most 4 events a second
/// per job), download statuses on every `STATUS_EVERY`th (10 s).
const SAMPLE: Duration = Duration::from_millis(250);
const STATUS_EVERY: u64 = 40;

/// Publish what changed in the jobs and the download statuses, while anyone listens.
/// With no clients it only sleeps; the first status sample after a client arrives is a
/// baseline, not a burst of events (the client fetched the list itself).
pub async fn pump<B: Backends>(st: Arc<WebState<B>>) -> anyhow::Result<()> {
    let mut statuses: Option<HashMap<u64, StatusDto>> = None;
    let mut sent: HashMap<String, crate::monitor::JobLive> = HashMap::new();
    let mut tick = tokio::time::interval(SAMPLE);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut n: u64 = 0;
    loop {
        tick.tick().await;
        if st.events.clients() == 0 {
            statuses = None;
            sent.clear();
            n = 0;
            continue;
        }
        let now = web::now();
        for (name, live) in st.monitor.snapshot() {
            if sent.get(&name) != Some(&live) {
                st.events
                    .publish(Event::Job(crate::api::job(&name, &live, &st.db, now)));
                sent.insert(name, live);
            }
        }
        if n.is_multiple_of(STATUS_EVERY) {
            let d = web::downloads(&st, now).await;
            let cur: HashMap<u64, StatusDto> = d
                .by_topic
                .iter()
                .map(|(id, s)| (*id, d.status_of(s)))
                .collect();
            if let Some(prev) = &statuses {
                for e in status_changes(prev, &cur) {
                    st.events.publish(e);
                }
            }
            statuses = Some(cur);
        }
        n += 1;
    }
}

#[cfg(test)]
#[path = "events_tests.rs"]
mod tests;
