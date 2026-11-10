use axum::{
    Router,
    body::Body,
    extract::State,
    http::{HeaderMap, StatusCode, header},
    response::IntoResponse,
    routing::{get, post},
};
use claude_board_bridge::voice::backends::{
    Brain, HermesHttp, PiperHttp, Stt, Tts, VoiceError, WhisperHttp,
};
use futures_util::StreamExt;
use std::sync::{Arc, Mutex, atomic::{AtomicUsize, Ordering}};
use std::time::Duration;

async fn serve(app: Router) -> String {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(l, app).await.unwrap() });
    format!("http://{addr}")
}

#[tokio::test]
async fn whisper_returns_the_transcript() {
    let seen: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(vec![]));
    let app = Router::new()
        .route(
            "/inference",
            post(|State(s): State<Arc<Mutex<Vec<u8>>>>, body: axum::body::Bytes| async move {
                *s.lock().unwrap() = body.to_vec();
                (
                    [(header::CONTENT_TYPE, "application/json")],
                    r#"{"text":" Sure, I checked\nthe session. \n"}"#,
                )
            }),
        )
        .with_state(seen.clone());
    let base = serve(app).await;
    let pcm = vec![1u8, 0, 2, 0, 3, 0, 4, 0];
    let text = WhisperHttp::new(base).transcribe(pcm.clone()).await.unwrap();
    assert_eq!(text, "Sure, I checked the session.");
    let body = seen.lock().unwrap().clone();
    assert!(body.windows(4).any(|w| w == b"RIFF"));
    assert!(body.windows(4).any(|w| w == b"WAVE"));
    let at = body.windows(4).position(|w| w == b"fmt ").unwrap();
    let rate = u32::from_le_bytes(body[at + 12..at + 16].try_into().unwrap());
    assert_eq!(rate, 16000);
    assert!(body.windows(pcm.len()).any(|w| w == pcm.as_slice()));
}

#[tokio::test]
async fn whisper_error_status_is_unavailable() {
    let app = Router::new().route("/inference", post(|| async { StatusCode::INTERNAL_SERVER_ERROR }));
    let base = serve(app).await;
    let err = WhisperHttp::new(base).transcribe(vec![0; 4]).await.unwrap_err();
    assert!(matches!(err, VoiceError::Unavailable(_)), "{err:?}");
}

fn wav(rate: u32, pcm: &[u8]) -> Vec<u8> {
    let mut v = Vec::new();
    v.extend_from_slice(b"RIFF");
    v.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
    v.extend_from_slice(b"WAVEfmt ");
    v.extend_from_slice(&16u32.to_le_bytes());
    v.extend_from_slice(&1u16.to_le_bytes());
    v.extend_from_slice(&1u16.to_le_bytes());
    v.extend_from_slice(&rate.to_le_bytes());
    v.extend_from_slice(&(rate * 2).to_le_bytes());
    v.extend_from_slice(&2u16.to_le_bytes());
    v.extend_from_slice(&16u16.to_le_bytes());
    v.extend_from_slice(b"data");
    v.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    v.extend_from_slice(pcm);
    v
}

#[tokio::test]
async fn piper_returns_pcm_and_rate() {
    let seen: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
    let app = Router::new()
        .route(
            "/synthesize",
            post(|State(s): State<Arc<Mutex<String>>>, body: String| async move {
                *s.lock().unwrap() = body;
                ([(header::CONTENT_TYPE, "audio/wav")], wav(22050, &[9, 8, 7, 6]))
            }),
        )
        .with_state(seen.clone());
    let base = serve(app).await;
    let sp = PiperHttp::new(base).synthesize("Hello there.".into()).await.unwrap();
    assert_eq!(sp.sample_rate, 22050);
    assert_eq!(sp.pcm, vec![9, 8, 7, 6]);
    let v: serde_json::Value = serde_json::from_str(&seen.lock().unwrap()).unwrap();
    assert_eq!(v["text"], "Hello there.");
}

#[derive(Clone, Default)]
struct Hermes {
    auth: Arc<Mutex<Option<String>>>,
    body: Arc<Mutex<Option<serde_json::Value>>>,
    stops: Arc<AtomicUsize>,
    hang: bool,
}

fn frame(i: u32, json: &str) -> String {
    format!("id: {i}\ndata: {json}\n\n")
}

async fn hermes_app(h: Hermes) -> String {
    let app = Router::new()
        .route(
            "/v1/runs",
            post(|State(h): State<Hermes>, headers: HeaderMap, body: axum::body::Bytes| async move {
                *h.auth.lock().unwrap() = headers
                    .get(header::AUTHORIZATION)
                    .map(|v| v.to_str().unwrap().to_string());
                *h.body.lock().unwrap() = serde_json::from_slice(&body).ok();
                (
                    StatusCode::ACCEPTED,
                    r#"{"run_id":"run_abc","status":"started","replayed":false}"#,
                )
            }),
        )
        .route(
            "/v1/runs/run_abc/events",
            get(|State(h): State<Hermes>| async move {
                let mut s = String::from(": open\n\n");
                s += &frame(1, r#"{"event":"message.delta","run_id":"run_abc","delta":"Hel","seq":1}"#);
                s += &frame(2, r#"{"event":"tool.started","run_id":"run_abc","seq":2}"#);
                s += &frame(3, r#"{"event":"message.delta","run_id":"run_abc","delta":"lo ","seq":3}"#);
                s += &frame(4, r#"{"event":"message.delta","run_id":"run_abc","delta":"there.","seq":4}"#);
                let head = futures_util::stream::once(async move {
                    Ok::<_, std::convert::Infallible>(axum::body::Bytes::from(s))
                });
                let body = if h.hang {
                    Body::from_stream(head.chain(futures_util::stream::pending()))
                } else {
                    let fin = frame(5, r#"{"event":"run.completed","run_id":"run_abc","output":"Hello there.","seq":5}"#);
                    let tail = futures_util::stream::once(async move {
                        Ok::<_, std::convert::Infallible>(axum::body::Bytes::from(fin))
                    });
                    Body::from_stream(head.chain(tail))
                };
                ([(header::CONTENT_TYPE, "text/event-stream")], body).into_response()
            }),
        )
        .route(
            "/v1/runs/run_abc/stop",
            post(|State(h): State<Hermes>| async move {
                h.stops.fetch_add(1, Ordering::SeqCst);
                r#"{"run_id":"run_abc","status":"stopping"}"#
            }),
        )
        .with_state(h);
    serve(app).await
}

#[tokio::test]
async fn hermes_streams_deltas_in_order() {
    let base = hermes_app(Hermes::default()).await;
    let brain = HermesHttp::new(base, "k".into(), "creature".into());
    let mut reply = brain.ask("hi".into()).await.unwrap();
    let mut got = vec![];
    while let Some(d) = reply.deltas.next().await {
        got.push(d.unwrap());
    }
    assert_eq!(got, vec!["Hel", "lo ", "there."]);
}

#[tokio::test]
async fn hermes_sends_bearer_key_and_session_id() {
    let h = Hermes::default();
    let base = hermes_app(h.clone()).await;
    let brain = HermesHttp::new(base, "secret-key".into(), "creature".into());
    let mut reply = brain.ask("what time".into()).await.unwrap();
    while reply.deltas.next().await.is_some() {}
    assert_eq!(h.auth.lock().unwrap().as_deref(), Some("Bearer secret-key"));
    let body = h.body.lock().unwrap().clone().unwrap();
    assert_eq!(body["session_id"], "creature");
    assert_eq!(body["input"], "what time");
}

#[tokio::test]
async fn dropping_a_reply_stops_the_run() {
    let h = Hermes { hang: true, ..Default::default() };
    let base = hermes_app(h.clone()).await;
    let brain = HermesHttp::new(base, "k".into(), "creature".into());
    let mut reply = brain.ask("hi".into()).await.unwrap();
    assert_eq!(reply.deltas.next().await.unwrap().unwrap(), "Hel");
    drop(reply);
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert_eq!(h.stops.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn finished_reply_does_not_call_stop() {
    let h = Hermes::default();
    let base = hermes_app(h.clone()).await;
    let brain = HermesHttp::new(base, "k".into(), "creature".into());
    let mut reply = brain.ask("hi".into()).await.unwrap();
    while reply.deltas.next().await.is_some() {}
    drop(reply);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(h.stops.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn unreachable_backend_is_unavailable_not_a_panic() {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", l.local_addr().unwrap());
    drop(l);
    let e = WhisperHttp::new(base.clone()).transcribe(vec![0; 4]).await.unwrap_err();
    assert!(matches!(e, VoiceError::Unavailable(_)), "{e:?}");
    let e = PiperHttp::new(base.clone()).synthesize("x".into()).await.unwrap_err();
    assert!(matches!(e, VoiceError::Unavailable(_)), "{e:?}");
    let e = HermesHttp::new(base, "k".into(), "s".into()).ask("x".into()).await.err().unwrap();
    assert!(matches!(e, VoiceError::Unavailable(_)), "{e:?}");
}
