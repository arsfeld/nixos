use axum::{
    Router,
    body::Body,
    extract::State,
    http::{HeaderMap, StatusCode, header},
    response::IntoResponse,
    routing::{get, post},
};
use cylon_bot_bridge::voice::backends::{
    Brain, HermesHttp, PiperHttp, Stt, Tts, VoiceError, WhisperHttp,
};
use futures_util::StreamExt;
use std::sync::{Arc, Mutex, atomic::{AtomicUsize, Ordering}};
use std::time::Duration;

fn sess(base: &str) -> Arc<cylon_bot_bridge::voice::session::SessionId> {
    Arc::new(cylon_bot_bridge::voice::session::SessionId::load(base.into(), None))
}

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
    post_hang: bool,
    /// Custom event stream: (delay in ms before the chunk, bytes).
    chunks: Option<Arc<Vec<(u64, Vec<u8>)>>>,
}

fn frame(i: u32, json: &str) -> String {
    format!("id: {i}\ndata: {json}\n\n")
}

async fn hermes_app(h: Hermes) -> String {
    let app = Router::new()
        .route(
            "/v1/runs",
            post(|State(h): State<Hermes>, headers: HeaderMap, body: axum::body::Bytes| async move {
                if h.post_hang {
                    std::future::pending::<()>().await;
                }
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
                if let Some(chunks) = h.chunks.clone() {
                    let hang = h.hang;
                    let st = futures_util::stream::unfold(0usize, move |i| {
                        let chunks = chunks.clone();
                        async move {
                            if i < chunks.len() {
                                tokio::time::sleep(Duration::from_millis(chunks[i].0)).await;
                                let b = axum::body::Bytes::from(chunks[i].1.clone());
                                Some((Ok::<_, std::convert::Infallible>(b), i + 1))
                            } else if hang {
                                std::future::pending().await
                            } else {
                                None
                            }
                        }
                    });
                    return ([(header::CONTENT_TYPE, "text/event-stream")], Body::from_stream(st))
                        .into_response();
                }
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
    let brain = HermesHttp::new(base, "k".into(), sess("creature"));
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
    let brain = HermesHttp::new(base, "secret-key".into(), sess("creature"));
    let mut reply = brain.ask("what time".into()).await.unwrap();
    while reply.deltas.next().await.is_some() {}
    assert_eq!(h.auth.lock().unwrap().as_deref(), Some("Bearer secret-key"));
    let body = h.body.lock().unwrap().clone().unwrap();
    assert_eq!(body["session_id"], "creature");
    assert_eq!(body["input"], "what time");
}

#[tokio::test]
async fn hermes_uses_the_new_session_after_reset() {
    let h = Hermes::default();
    let base = hermes_app(h.clone()).await;
    let brain = HermesHttp::new(base, "k".into(), sess("creature"));
    brain.new_session();
    let mut reply = brain.ask("hi".into()).await.unwrap();
    while reply.deltas.next().await.is_some() {}
    let body = h.body.lock().unwrap().clone().unwrap();
    let id = body["session_id"].as_str().unwrap().to_string();
    assert!(id.starts_with("creature-"), "{id}");
    assert_ne!(id, "creature");
}

#[tokio::test]
async fn dropping_a_reply_stops_the_run() {
    let h = Hermes { hang: true, ..Default::default() };
    let base = hermes_app(h.clone()).await;
    let brain = HermesHttp::new(base, "k".into(), sess("creature"));
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
    let brain = HermesHttp::new(base, "k".into(), sess("creature"));
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
    let e = HermesHttp::new(base, "k".into(), sess("s")).ask("x".into()).await.err().unwrap();
    assert!(matches!(e, VoiceError::Unavailable(_)), "{e:?}");
}

fn chunked(chunks: Vec<(u64, &str)>, hang: bool) -> Hermes {
    Hermes {
        hang,
        chunks: Some(Arc::new(chunks.into_iter().map(|(d, b)| (d, b.as_bytes().to_vec())).collect())),
        ..Default::default()
    }
}

async fn collect(h: Hermes) -> (Vec<Result<String, VoiceError>>, Hermes) {
    let base = hermes_app(h.clone()).await;
    let brain = HermesHttp::new(base, "k".into(), sess("s"));
    let mut reply = brain.ask("hi".into()).await.unwrap();
    let mut out = vec![];
    while let Some(d) = reply.deltas.next().await {
        out.push(d);
    }
    (out, h)
}

fn ok(v: &[Result<String, VoiceError>]) -> Vec<String> {
    v.iter().map(|r| r.as_ref().unwrap().clone()).collect()
}

const DONE: &str = r#"data: {"event":"run.completed","output":"x","seq":9}"#;

#[tokio::test]
async fn hermes_post_that_never_answers_times_out() {
    let h = Hermes { post_hang: true, ..Default::default() };
    let base = hermes_app(h).await;
    let brain = HermesHttp::new(base, "k".into(), sess("s"))
        .with_timeouts(Duration::from_millis(150), Duration::from_secs(30));
    let e = brain.ask("hi".into()).await.err().unwrap();
    assert!(matches!(e, VoiceError::Timeout), "{e:?}");
}

#[tokio::test]
async fn hermes_stream_that_goes_silent_yields_a_timeout_error() {
    let h = chunked(vec![(0, "data: {\"event\":\"message.delta\",\"delta\":\"Hi\"}\n\n")], true);
    let base = hermes_app(h.clone()).await;
    let brain = HermesHttp::new(base, "k".into(), sess("s"))
        .with_timeouts(Duration::from_secs(30), Duration::from_millis(200));
    let mut reply = brain.ask("hi".into()).await.unwrap();
    assert_eq!(reply.deltas.next().await.unwrap().unwrap(), "Hi");
    let e = reply.deltas.next().await.unwrap().unwrap_err();
    assert!(matches!(e, VoiceError::Timeout), "{e:?}");
    assert!(reply.deltas.next().await.is_none());
    drop(reply);
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(h.stops.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn slow_but_steady_stream_is_not_cut_off() {
    let mut chunks: Vec<(u64, String)> = (0..8)
        .map(|i| (40, format!("data: {{\"event\":\"message.delta\",\"delta\":\"{i}\"}}\n\n")))
        .collect();
    chunks.push((40, format!("{DONE}\n\n")));
    let h = chunked(chunks.iter().map(|(d, s)| (*d, s.as_str())).collect(), false);
    let base = hermes_app(h).await;
    let brain = HermesHttp::new(base, "k".into(), sess("s"))
        .with_timeouts(Duration::from_secs(30), Duration::from_millis(150));
    let mut reply = brain.ask("hi".into()).await.unwrap();
    let mut got = vec![];
    while let Some(d) = reply.deltas.next().await {
        got.push(d.unwrap());
    }
    assert_eq!(got.len(), 8);
}

#[tokio::test]
async fn sse_crlf_framing() {
    let h = chunked(vec![(0, "data: {\"event\":\"message.delta\",\"delta\":\"A\"}\r\n\r\ndata: {\"event\":\"message.delta\",\"delta\":\"B\"}\r\n\r\n")], false);
    let (out, _) = collect(h).await;
    assert_eq!(ok(&out), vec!["A", "B"]);
}

#[tokio::test]
async fn sse_frame_split_across_chunks() {
    let h = chunked(
        vec![
            (0, "da"),
            (10, "ta: {\"event\":\"message.delta\",\"delta\":\"Hey\"}\r\n\r"),
            (10, "\n"),
            (10, "data: {\"event\":\"message.delta\",\"delta\":\"You\"}\n\n"),
        ],
        false,
    );
    let (out, _) = collect(h).await;
    assert_eq!(ok(&out), vec!["Hey", "You"]);
}

#[tokio::test]
async fn sse_utf8_character_split_across_chunks() {
    let frame = "data: {\"event\":\"message.delta\",\"delta\":\"caf\u{e9} \u{6771}\"}\n\n".as_bytes().to_vec();
    let e = frame.iter().position(|&b| b == 0xC3).unwrap();
    let t = frame.iter().position(|&b| b == 0xE6).unwrap();
    let h = Hermes {
        chunks: Some(Arc::new(vec![
            (0, frame[..e + 1].to_vec()),
            (10, frame[e + 1..t + 1].to_vec()),
            (10, frame[t + 1..].to_vec()),
        ])),
        ..Default::default()
    };
    let (out, _) = collect(h).await;
    assert_eq!(ok(&out), vec!["caf\u{e9} \u{6771}"]);
}

#[tokio::test]
async fn sse_multiline_data_field() {
    let h = chunked(vec![(0, "data: {\"event\":\"message.delta\",\ndata: \"delta\":\"Joined\"}\n\n")], false);
    let (out, _) = collect(h).await;
    assert_eq!(ok(&out), vec!["Joined"]);
}

#[tokio::test]
async fn sse_comment_and_unknown_events_are_ignored() {
    let h = chunked(
        vec![(
            0,
            ": keepalive\n\nid: 1\ndata: {\"event\":\"reasoning.available\",\"x\":1}\n\nevent: weird\ndata: not json\n\ndata: {\"event\":\"message.delta\",\"delta\":\"Ok\"}\n\n",
        )],
        false,
    );
    let (out, _) = collect(h).await;
    assert_eq!(ok(&out), vec!["Ok"]);
}

#[tokio::test]
async fn sse_oversized_event_is_rejected() {
    let big = "x".repeat(1_100_000);
    let h = chunked(vec![(0, "data: "), (0, big.as_str())], false);
    let (out, _) = collect(h).await;
    assert!(matches!(out.last().unwrap(), Err(VoiceError::Rejected(m)) if m == "event too large"), "{out:?}");
}

#[tokio::test]
async fn hermes_run_failed_event_ends_the_stream_and_stop_is_still_sent() {
    let h = chunked(
        vec![(0, "data: {\"event\":\"message.delta\",\"delta\":\"Hi\"}\n\ndata: {\"event\":\"run.failed\",\"error\":\"boom\"}\n\n")],
        false,
    );
    let base = hermes_app(h.clone()).await;
    let brain = HermesHttp::new(base, "k".into(), sess("s"));
    let mut reply = brain.ask("hi".into()).await.unwrap();
    assert_eq!(reply.deltas.next().await.unwrap().unwrap(), "Hi");
    let e = reply.deltas.next().await.unwrap().unwrap_err();
    assert!(matches!(e, VoiceError::Rejected(ref m) if m.contains("boom")), "{e:?}");
    assert!(reply.deltas.next().await.is_none());
    drop(reply);
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(h.stops.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn whisper_wav_header_and_field_name() {
    let seen: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(vec![]));
    let app = Router::new()
        .route(
            "/inference",
            post(|State(s): State<Arc<Mutex<Vec<u8>>>>, body: axum::body::Bytes| async move {
                *s.lock().unwrap() = body.to_vec();
                r#"{"text":"x"}"#
            }),
        )
        .with_state(seen.clone());
    let base = serve(app).await;
    let pcm = vec![5u8; 10];
    WhisperHttp::new(base).transcribe(pcm).await.unwrap();
    let body = seen.lock().unwrap().clone();
    let find = |n: &[u8]| body.windows(n.len()).position(|w| w == n).unwrap();
    assert!(find(b"name=\"file\"") > 0);
    let r = find(b"RIFF");
    let h = &body[r..r + 44];
    let u32at = |o: usize| u32::from_le_bytes(h[o..o + 4].try_into().unwrap());
    let u16at = |o: usize| u16::from_le_bytes(h[o..o + 2].try_into().unwrap());
    assert_eq!(u32at(4), 36 + 10);
    assert_eq!(u16at(20), 1);
    assert_eq!(u16at(22), 1);
    assert_eq!(u32at(24), 16000);
    assert_eq!(u32at(28), 32000);
    assert_eq!(u16at(32), 2);
    assert_eq!(u16at(34), 16);
    assert_eq!(&h[36..40], b"data");
    assert_eq!(u32at(40), 10);
}
