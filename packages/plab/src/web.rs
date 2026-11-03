//! plab's HTTP server: the JSON API under /api, its SSE stream, the app's built files under /assets, and the app's index.html for every other path (the app routes itself). Plus the tailnet listener that only reads streams.

use crate::api::{self, Downloads, SearchReply};
use crate::db::{Db, Listing, Section};
use crate::events::{self, Event, Events};
use crate::filters::{excluded, load_excludes};
use crate::images::{ImageCache, key};
use crate::monitor::Monitor;
use crate::plab::{self, Ctx, NotListed};
use crate::provenance::{self, Status};
use crate::prowlarr::Prowlarr;
use crate::rqbit::Rqbit;
use crate::stream::{self, StreamError, Streams};
use crate::tracker::TrackerApi;
use crate::transmission::TorrentClient;
use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, Method, Response, StatusCode, Uri, header};
use futures::StreamExt;
use serde::Serialize;
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tracing::info;

pub struct WebState<T: TrackerApi, C: TorrentClient> {
    pub tracker: Arc<T>,
    pub torrents: Arc<C>,
    pub db: Db,
    pub images: ImageCache,
    pub state_dir: PathBuf,
    pub exclude_file: Option<PathBuf>,
    pub filter_file: Option<PathBuf>,
    pub download_dir: String,
    pub games_dir: Option<String>,
    /// Stash's web address, for links to a download's scenes.
    pub stash_web_url: Option<String>,
    pub static_dir: Option<PathBuf>,
    pub fetch_slots: Arc<tokio::sync::Semaphore>,
    /// One add at a time: the add is a read-modify-write of the database's added set.
    pub add_lock: Arc<tokio::sync::Mutex<()>>,
    /// The stream engine; None when PLAB_RQBIT_URL is unset (streams answer 502).
    pub engine: Option<Rqbit>,
    pub streams: Arc<Streams>,
    /// The tailnet listener's public base, for the "Copy URL for VLC" button.
    pub stream_public_url: Option<String>,
    /// Live updates to every connected app.
    pub events: Events,
    pub monitor: Monitor,
    /// Other indexers' torrents, for releases from them; None when Prowlarr is unset.
    pub prowlarr: Option<Arc<Prowlarr>>,
}

impl<T: TrackerApi, C: TorrentClient> WebState<T, C> {
    fn ctx(&self) -> Ctx<'_, T, C> {
        Ctx {
            tracker: &*self.tracker,
            torrents: &*self.torrents,
            db: &self.db,
            images: &self.images,
            state_dir: &self.state_dir,
            exclude_file: self.exclude_file.as_deref(),
            filter_file: self.filter_file.as_deref(),
            download_dir: &self.download_dir,
            games_dir: self.games_dir.as_deref(),
            delay: plab::DELAY,
            fetch_slots: &self.fetch_slots,
            prowlarr: self.prowlarr.as_deref(),
        }
    }
}

pub fn router<T: TrackerApi + 'static, C: TorrentClient + 'static>(
    state: Arc<WebState<T, C>>,
) -> Router {
    Router::new().fallback(handle::<T, C>).with_state(state)
}

pub async fn serve(router: Router, bind: &str, port: u16) -> anyhow::Result<()> {
    let listener = tokio::net::TcpListener::bind((bind, port)).await?;
    info!(job = "web", "serving on {bind}:{port}");
    axum::serve(listener, router).await?;
    Ok(())
}

pub(crate) fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn send(code: u16, body: impl Into<Body>, ctype: &str, cache: &str) -> Response<Body> {
    Response::builder()
        .status(code)
        .header(header::CONTENT_TYPE, ctype)
        .header(header::CACHE_CONTROL, cache)
        .body(body.into())
        .unwrap()
}

fn text(code: u16, body: impl Into<String>) -> Response<Body> {
    send(code, body.into(), "text/plain", "no-store")
}

fn redirect(location: &str) -> Response<Body> {
    Response::builder()
        .status(StatusCode::FOUND)
        .header(header::LOCATION, location)
        .body(Body::empty())
        .unwrap()
}

fn not_found() -> Response<Body> {
    text(404, "not found")
}

/// `re.fullmatch(r"/<prefix>/(\d+)", path)`.
fn id_after(path: &str, prefix: &str) -> Option<u64> {
    let digits = path.strip_prefix(prefix)?.strip_prefix('/')?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum StreamRoute {
    Topic(u64),
    Select(u64, usize),
    File(u64, usize),
}

fn stream_route(path: &str) -> Option<StreamRoute> {
    fn num(s: &str) -> Option<u64> {
        (!s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())).then(|| s.parse().ok())?
    }
    let parts: Vec<&str> = path.strip_prefix("/stream/")?.split('/').collect();
    match parts.as_slice() {
        [t] => Some(StreamRoute::Topic(num(t)?)),
        [t, "select", f] => Some(StreamRoute::Select(num(t)?, num(f)? as usize)),
        [t, f] => Some(StreamRoute::File(num(t)?, num(f)? as usize)),
        _ => None,
    }
}

fn json_reply(code: u16, v: Value) -> Response<Body> {
    send(code, v.to_string(), "application/json", "no-store")
}

fn stream_error(e: StreamError) -> Response<Body> {
    info!(job = "web", "stream: {e}");
    json_reply(e.status(), json!({"ok": false, "error": e.to_string()}))
}

/// `{"ok": true}` merged with the value's own fields.
fn ok_reply<V: Serialize>(v: V, extra: Value) -> Response<Body> {
    let mut m = Map::new();
    m.insert("ok".into(), true.into());
    if let Value::Object(fields) = serde_json::to_value(v).unwrap_or(Value::Null) {
        m.extend(fields);
    }
    if let Value::Object(fields) = extra {
        m.extend(fields);
    }
    json_reply(200, Value::Object(m))
}

async fn stream_page<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    method: Method,
    route: StreamRoute,
    range: Option<&str>,
) -> Response<Body> {
    let Some(engine) = &st.engine else {
        return stream_error(StreamError::Engine("PLAB_RQBIT_URL is not set".into()));
    };
    let external = |topic: u64, file: usize| {
        st.stream_public_url
            .as_ref()
            .map(|b| format!("{}/stream/{topic}/{file}", b.trim_end_matches('/')))
    };
    let started = |r: Result<stream::StreamInfo, StreamError>| match r {
        Ok(info) => {
            let ext = external(info.topic, info.selected);
            ok_reply(info, json!({ "external": ext }))
        }
        Err(e) => stream_error(e),
    };
    match (method, route) {
        (Method::GET, StreamRoute::File(t, f)) => {
            stream_file(&st.streams, engine, t, f, range).await
        }
        (Method::GET, StreamRoute::Topic(t)) => match st.streams.stats(engine, t, now()).await {
            Ok(stream::StreamStatus::Live(stats)) => ok_reply(json!({}), json!({ "stats": stats })),
            Ok(stream::StreamStatus::Starting(s)) => ok_reply(json!({}), json!({ "starting": s })),
            Err(e) => stream_error(e),
        },
        (Method::POST, StreamRoute::Topic(t)) => started(
            st.streams
                .start(
                    &*st.tracker,
                    st.prowlarr.as_deref(),
                    &st.db,
                    engine,
                    t,
                    now(),
                )
                .await,
        ),
        (Method::POST, StreamRoute::Select(t, f)) => {
            started(st.streams.select(engine, t, f, now()).await)
        }
        (Method::DELETE, StreamRoute::Topic(t)) => match st.streams.stop(engine, t).await {
            Ok(()) => ok_reply(json!({}), json!({})),
            Err(e) => stream_error(e),
        },
        _ => text(405, "method not allowed"),
    }
}

/// The bytes of a stream, passed through from rqbit. Each chunk that reaches the client
/// counts as a read, so one long-running request keeps its stream from the reaper.
async fn stream_file(
    streams: &Arc<Streams>,
    engine: &Rqbit,
    topic: u64,
    file: usize,
    range: Option<&str>,
) -> Response<Body> {
    let (up, name) = match streams.open(engine, topic, file, range, now()).await {
        Ok(v) => v,
        Err(e) => return stream_error(e),
    };
    let reads = streams.clone();
    let body = Body::from_stream(
        up.body
            .into_data_stream()
            .inspect(move |_| reads.touch(topic, now())),
    );
    let mut resp = Response::builder()
        .status(up.status)
        .header(header::CONTENT_TYPE, stream::content_type(&name))
        .header(header::CACHE_CONTROL, "no-store");
    for (k, v) in up.headers {
        resp = resp.header(k, v);
    }
    resp.body(body).unwrap()
}

/// The tailnet listener: reads a stream that was started on the gated page, nothing else.
pub fn stream_router<T: TrackerApi + 'static, C: TorrentClient + 'static>(
    state: Arc<WebState<T, C>>,
) -> Router {
    Router::new().fallback(tailnet::<T, C>).with_state(state)
}

async fn tailnet<T: TrackerApi + 'static, C: TorrentClient + 'static>(
    State(st): State<Arc<WebState<T, C>>>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
) -> Response<Body> {
    // HEAD as GET: players probe with it, and the server drops a HEAD reply's body.
    if method != Method::GET && method != Method::HEAD {
        return text(405, "method not allowed");
    }
    let Some(StreamRoute::File(topic, file)) = stream_route(uri.path()) else {
        return not_found();
    };
    let Some(engine) = &st.engine else {
        return stream_error(StreamError::Engine("PLAB_RQBIT_URL is not set".into()));
    };
    let range = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
    stream_file(&st.streams, engine, topic, file, range).await
}

async fn handle<T: TrackerApi + 'static, C: TorrentClient + 'static>(
    State(st): State<Arc<WebState<T, C>>>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
) -> Response<Body> {
    let path = uri.path();
    if let Some(route) = path.strip_prefix("/api").and_then(stream_route) {
        let range = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
        return stream_page(&st, method, route, range).await;
    }
    match method {
        Method::GET => get(&st, path, uri.query()).await,
        Method::POST => post(&st, path).await,
        _ => not_found(),
    }
}

async fn get<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    path: &str,
    query: Option<&str>,
) -> Response<Body> {
    if let Some(rest) = path.strip_prefix("/api/") {
        return api_get(st, rest, query).await;
    }
    if let Some(name) = path.strip_prefix("/assets/") {
        return asset(st.static_dir.as_deref(), name).await;
    }
    index(st.static_dir.as_deref()).await
}

fn param(query: Option<&str>, name: &str) -> Option<String> {
    form_urlencoded::parse(query.unwrap_or("").as_bytes())
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.into_owned())
}

fn json_body<V: Serialize>(v: &V) -> Response<Body> {
    send(
        200,
        serde_json::to_string(v).expect("json"),
        "application/json",
        "no-store",
    )
}

async fn api_get<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    path: &str,
    query: Option<&str>,
) -> Response<Body> {
    match path {
        "list" => {
            return match param(query, "section").as_deref() {
                None | Some("video") => list(st, Section::Video).await,
                Some("games") => list(st, Section::Games).await,
                Some(_) => text(400, "section is video or games"),
            };
        }
        "search" => {
            let q = param(query, "q")
                .map(|q| q.trim().to_string())
                .unwrap_or_default();
            if q.is_empty() {
                return text(400, "q is required");
            }
            return search(st, &q).await;
        }
        "grabs" => {
            let t = now();
            return json_body(&api::grabs(&downloads(st, t).await, t));
        }
        "jobs" => return json_body(&api::jobs(&st.monitor, &st.db, now())),
        "events" => return events::sse(&st.events),
        _ => {}
    }
    let slashed = format!("/{path}");
    for kind in ["thumb", "images"] {
        if let Some(id) = id_after(&slashed, &format!("/{kind}")) {
            return topic_images(st, kind, id).await;
        }
    }
    if let Some(k) = path.strip_prefix("img/")
        && k.len() == 40
        && k.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
    {
        match plab::image_for(&st.ctx(), k, now()).await {
            Err(e) => {
                info!(job = "web", "image {k}: {e}");
                return text(502, "image unavailable");
            }
            Ok(Some((data, ctype))) => return send(200, data, ctype, "private, max-age=604800"),
            Ok(None) => {}
        }
    }
    not_found()
}

/// The content type of a built asset by extension; anything else is not served.
fn asset_type(name: &str) -> Option<&'static str> {
    match name.rsplit_once('.')?.1 {
        "js" => Some("text/javascript; charset=utf-8"),
        "css" => Some("text/css; charset=utf-8"),
        "svg" => Some("image/svg+xml"),
        "woff2" => Some("font/woff2"),
        "png" => Some("image/png"),
        _ => None,
    }
}

/// A file from the build's assets/. Its name carries its hash, so it is cached forever.
async fn asset(dir: Option<&Path>, name: &str) -> Response<Body> {
    let plain =
        !name.is_empty() && !name.contains('/') && !name.contains("..") && !name.starts_with('.');
    let (Some(dir), Some(ctype)) = (dir, plain.then(|| asset_type(name)).flatten()) else {
        return not_found();
    };
    match tokio::fs::read(dir.join("assets").join(name)).await {
        Ok(data) => send(200, data, ctype, "private, max-age=31536000, immutable"),
        Err(_) => not_found(),
    }
}

/// The app's shell, for every path the app routes itself. Never cached: it names the
/// current build's assets.
async fn index(dir: Option<&Path>) -> Response<Body> {
    let Some(dir) = dir else {
        return text(503, "the app is not built: PLAB_STATIC_DIR is not set");
    };
    match tokio::fs::read(dir.join("index.html")).await {
        Ok(body) => send(200, body, "text/html; charset=utf-8", "no-cache"),
        Err(_) => text(
            503,
            "the app is not built: PLAB_STATIC_DIR has no index.html",
        ),
    }
}

/// How far back the page looks up downloads in Transmission, and shows grabs.
const LIVE_DAYS: i64 = 30;
const GRAB_DAYS: i64 = 14;

/// Each recent download's status. Transmission is asked once, briefly; if it does not
/// answer, statuses come from the database alone.
pub(crate) async fn downloads<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    now: i64,
) -> Downloads {
    let rows = match st.db.download_rows(now - LIVE_DAYS * 86400) {
        Ok(r) => r,
        Err(e) => {
            info!(job = "web", "download rows: {e:#}");
            return Downloads {
                stash: st.stash_web_url.clone(),
                ..Downloads::default()
            };
        }
    };
    let hashes: Vec<String> = rows.iter().filter_map(|r| r.hash.clone()).collect();
    let live = match tokio::time::timeout(
        std::time::Duration::from_secs(2),
        st.torrents.details(&hashes),
    )
    .await
    {
        Ok(Ok(list)) => Some(
            list.into_iter()
                .map(|d| (d.hash_string.clone(), d))
                .collect::<HashMap<_, _>>(),
        ),
        Ok(Err(e)) => {
            info!(job = "web", "transmission: {e:#}");
            None
        }
        Err(_) => {
            info!(job = "web", "transmission: no answer in 2 s");
            None
        }
    };
    let mut out = Downloads {
        stash: st.stash_web_url.clone(),
        ..Downloads::default()
    };
    for r in rows {
        let s: Status = provenance::status(&r, live.as_ref(), now);
        if let Some(t) = r.topic_id {
            out.by_topic.insert(t, s);
        } else if r.source == "grab" && r.added_at.is_some_and(|a| a >= now - GRAB_DAYS * 86400) {
            out.grabs.push((r, s));
        }
    }
    out
}

async fn search<T: TrackerApi, C: TorrentClient>(st: &WebState<T, C>, q: &str) -> Response<Body> {
    let t = now();
    let (topics, error) = match plab::run_search(&st.ctx(), q, t).await {
        Ok(topics) => (topics, None),
        Err(e) => {
            info!(job = "web", "search {q:?} failed: {e}");
            (vec![], Some(e.to_string()))
        }
    };
    let downloads = downloads(st, t).await;
    let reply = st.db.listing(Section::Video).and_then(|l| {
        let listing = Listing { topics, ..l };
        let queued = st.db.queued(Section::Video)?.into_iter().collect();
        let externals = st.db.externals()?;
        Ok(api::list(
            &listing,
            &st.db.added()?,
            &queued,
            t,
            Section::Video,
            &downloads,
            Some(SearchReply {
                query: q.to_string(),
                error,
            }),
            &externals,
        ))
    });
    match reply {
        Ok(v) => json_body(&v),
        Err(e) => text(500, e.to_string()),
    }
}

async fn list<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    section: Section,
) -> Response<Body> {
    let t = now();
    let downloads = downloads(st, t).await;
    let reply = st.db.listing(section).and_then(|mut listing| {
        let patterns = load_excludes(st.exclude_file.as_deref(), Some(&st.state_dir));
        if !patterns.is_empty() {
            listing
                .topics
                .retain(|t| !excluded(&patterns, &t.topic.row.title));
        }
        let queued = st.db.queued(section)?.into_iter().collect();
        let externals = st.db.externals()?;
        Ok(api::list(
            &listing,
            &st.db.added()?,
            &queued,
            t,
            section,
            &downloads,
            None,
            &externals,
        ))
    });
    match reply {
        Ok(v) => json_body(&v),
        Err(e) => text(500, e.to_string()),
    }
}

async fn topic_images<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    kind: &str,
    id: u64,
) -> Response<Body> {
    let ctx = st.ctx();
    let images = match plab::topic_images(&ctx, id, now()).await {
        Ok(images) => images,
        Err(e) => return images_error(kind, id, e),
    };
    if kind == "images" {
        let keys: Vec<Value> = images.iter().map(|u| json!(key(u))).collect();
        let body = serde_json::to_string(&json!({ "images": keys })).expect("json");
        return send(200, body, "application/json", "no-store");
    }
    let Some(first) = images.first() else {
        return text(404, "no images");
    };
    if let Err(e) = plab::ensure_image(ctx.tracker, ctx.images, first).await {
        return images_error(kind, id, e);
    }
    redirect(&format!("../img/{}", key(first)))
}

/// Python's `except ValueError` (not listed, or not an image) is a 404 with the message;
/// anything else leaves the card on its placeholder.
fn images_error(kind: &str, id: u64, e: anyhow::Error) -> Response<Body> {
    if e.is::<NotListed>() || e.to_string().starts_with("not an image: ") {
        return text(404, e.to_string());
    }
    info!(job = "web", "{kind} {id}: {e}");
    text(502, "images unavailable")
}

async fn post<T: TrackerApi, C: TorrentClient>(st: &WebState<T, C>, path: &str) -> Response<Body> {
    let Some((action, id)) = ["add", "unqueue"]
        .into_iter()
        .find_map(|a| id_after(path, &format!("/api/{a}")).map(|id| (a, id)))
    else {
        return not_found();
    };
    let result: anyhow::Result<AddReply> = {
        let _lock = st.add_lock.lock().await;
        let ctx = st.ctx();
        if action == "unqueue" {
            plab::unqueue_topic(&st.db, id).map(|()| AddReply::ok())
        } else {
            plab::add_topic(&ctx, id, now()).await.map(|r| match r {
                plab::AddResult::Added { name } => AddReply {
                    name: Some(name),
                    ..AddReply::ok()
                },
                plab::AddResult::AlreadyAdded => AddReply {
                    name: Some("already added".into()),
                    ..AddReply::ok()
                },
                plab::AddResult::Queued { message } => AddReply {
                    queued: Some(true),
                    message: Some(message),
                    ..AddReply::ok()
                },
            })
        }
    };
    let (code, reply) = match result {
        Ok(reply) => {
            let state = if action == "unqueue" {
                ""
            } else if reply.queued == Some(true) {
                "queued"
            } else {
                "added"
            };
            st.events.publish(Event::TopicState { id, state });
            info!(job = "web", "{action} {id}: {}", reply.json());
            (200, reply)
        }
        Err(e) => {
            info!(job = "web", "{action} {id} failed: {e}");
            (
                502,
                AddReply {
                    ok: false,
                    error: Some(e.to_string()),
                    ..AddReply::ok()
                },
            )
        }
    };
    send(code, reply.json(), "application/json", "no-store")
}

/// The JSON reply to an add or unqueue. Field order is the wire order.
#[derive(serde::Serialize)]
struct AddReply {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    queued: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl AddReply {
    fn ok() -> AddReply {
        AddReply {
            ok: true,
            queued: None,
            name: None,
            message: None,
            error: None,
        }
    }

    fn json(&self) -> String {
        serde_json::to_string(self).expect("json")
    }
}

#[cfg(test)]
#[path = "web_tests.rs"]
mod tests;
