use super::*;
use crate::api::StatusDto;
use futures::StreamExt;
use serde_json::json;
use std::collections::HashMap;

#[test]
fn events_serialize_with_their_type() {
    let cases = [
        (
            Event::TopicState {
                id: 1,
                state: "added",
            },
            json!({"type": "topicState", "id": 1, "state": "added"}),
        ),
        (
            Event::TopicStatus {
                id: 2,
                status: Some(StatusDto::Added),
            },
            json!({"type": "topicStatus", "id": 2, "status": {"kind": "added"}}),
        ),
        (
            Event::TopicStatus {
                id: 3,
                status: None,
            },
            json!({"type": "topicStatus", "id": 3, "status": null}),
        ),
        (
            Event::Listing { section: "games" },
            json!({"type": "listing", "section": "games"}),
        ),
        (Event::Resync, json!({"type": "resync"})),
    ];
    for (e, want) in cases {
        assert_eq!(serde_json::to_value(&e).unwrap(), want);
    }
}

#[test]
fn a_job_event_is_its_entry_with_a_type() {
    let job = crate::api::JobDto {
        name: "grab".into(),
        state: "idle",
        since: None,
        pending: None,
        restart_at: None,
        next: Some(5),
        step: None,
        progress: None,
        lines: vec![],
        runs: vec![],
    };
    let v = serde_json::to_value(Event::Job(job)).unwrap();
    assert_eq!(
        (v["type"].clone(), v["name"].clone(), v["next"].clone()),
        (json!("job"), json!("grab"), json!(5))
    );
}

#[tokio::test]
async fn a_lagging_client_gets_resync_then_the_newest() {
    let ev = Events::with_capacity(1);
    let mut s = Box::pin(stream(ev.subscribe()));
    for section in ["video", "games", "video"] {
        ev.publish(Event::Listing { section });
    }
    assert_eq!(s.next().await, Some(Event::Resync));
    assert_eq!(s.next().await, Some(Event::Listing { section: "video" }));
}

#[test]
fn publish_without_clients_or_global_is_harmless() {
    Events::default().publish(Event::Resync);
    publish(Event::Resync); // the global is never set in tests
}

#[test]
fn status_changes_report_new_changed_and_gone_topics() {
    let prev = HashMap::from([
        (1, StatusDto::Added),
        (3, StatusDto::Queued),
        (4, StatusDto::Added),
    ]);
    let cur = HashMap::from([
        (1, StatusDto::Downloading { percent: 50 }),
        (2, StatusDto::Queued),
        (4, StatusDto::Added),
    ]);
    assert_eq!(
        status_changes(&prev, &cur),
        vec![
            Event::TopicStatus {
                id: 1,
                status: Some(StatusDto::Downloading { percent: 50 })
            },
            Event::TopicStatus {
                id: 2,
                status: Some(StatusDto::Queued)
            },
            Event::TopicStatus {
                id: 3,
                status: None
            },
        ]
    );
}
