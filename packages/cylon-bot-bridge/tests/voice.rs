//! The voice pipeline served over the board's websocket, against in-process fake backends.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use cylon_bot_bridge::protocol::{decode_audio, encode_audio};
use cylon_bot_bridge::http::AppState;
use cylon_bot_bridge::voice::VoiceConfig;
use cylon_bot_bridge::voice::backends::Backends;
use common::{DEVICE_TOKEN, FakeBrain, FakeStt, FakeTts, Ws, next_json, serve, state, try_connect};
use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;

mod common;

fn voiced(brain: Arc<FakeBrain>, tts_bytes: usize) -> AppState {
    let backends = Backends { stt: FakeStt::new("hello"), tts: Arc::new(FakeTts { bytes: tts_bytes, hang: false }), brain };
    state(1000).with_voice(backends, VoiceConfig::default())
}

/// Connects and consumes hello, the snapshot and the creature's first mood.
async fn connect_voice(addr: std::net::SocketAddr) -> (Ws, Value) {
    let mut ws = try_connect(addr, Some(DEVICE_TOKEN)).await.unwrap();
    assert_eq!(next_json(&mut ws).await["t"], "hello");
    assert_eq!(next_json(&mut ws).await["t"], "state");
    let mood = next_json(&mut ws).await;
    (ws, mood)
}

async fn send_json(ws: &mut Ws, v: Value) {
    ws.send(Message::text(v.to_string())).await.unwrap();
}

async fn say(ws: &mut Ws, id: u32) {
    send_json(ws, json!({"t":"voice_start","utterance":id})).await;
    ws.send(Message::binary(encode_audio(id, &[0u8; 3200]))).await.unwrap();
    send_json(ws, json!({"t":"voice_end","utterance":id})).await;
}

enum Got {
    Json(Value),
    Audio(Vec<u8>),
}

async fn next_frame(ws: &mut Ws) -> Got {
    loop {
        let m = tokio::time::timeout(Duration::from_secs(5), ws.next()).await.expect("frame").unwrap().unwrap();
        match m {
            Message::Text(t) => return Got::Json(serde_json::from_str(t.as_str()).unwrap()),
            Message::Binary(b) => return Got::Audio(b.to_vec()),
            _ => {}
        }
    }
}

async fn wait_for(what: &str, mut cond: impl FnMut() -> bool) {
    for _ in 0..150 {
        if cond() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("never happened: {what}");
}

#[tokio::test]
async fn voice_round_trip_over_the_socket() {
    let st = voiced(FakeBrain::new(&[(0, "Hi there. "), (0, "Second one.")], false), 2000);
    let addr = serve(st).await;
    let (mut ws, mood) = connect_voice(addr).await;
    assert_eq!(mood, json!({"t":"creature","mood":"idle"}));
    say(&mut ws, 7).await;

    let mut tags = Vec::new();
    let mut audio = 0;
    loop {
        match next_frame(&mut ws).await {
            Got::Json(v) => {
                let t = v["t"].as_str().unwrap().to_string();
                if t == "transcript" {
                    assert_eq!(v["utterance"], 7);
                    assert_eq!(v["text"], "hello");
                }
                let end = t == "speak_end";
                tags.push(t);
                if end {
                    break;
                }
            }
            Got::Audio(b) => {
                let (id, pcm) = decode_audio(&b).expect("audio frame");
                assert_eq!(id, 7);
                assert!(!pcm.is_empty());
                audio += 1;
            }
        }
    }
    assert!(audio >= 1);
    let pos = |t: &str| tags.iter().position(|x| x == t).unwrap_or_else(|| panic!("no {t} in {tags:?}"));
    assert!(pos("creature") < pos("transcript"));
    assert!(pos("transcript") < pos("reply_text"));
    assert!(pos("speak_start") < pos("speak_end"));
    // Idle follows the end of the turn.
    loop {
        if let Got::Json(v) = next_frame(&mut ws).await {
            if v["t"] == "creature" && v["mood"] == "idle" {
                break;
            }
        }
    }
}

#[tokio::test]
async fn voice_reply_reaches_only_the_speaking_socket() {
    let st = voiced(FakeBrain::new(&[(0, "Hi there.")], false), 2000);
    let addr = serve(st).await;
    let (mut a, _) = connect_voice(addr).await;
    let (mut b, _) = connect_voice(addr).await;
    say(&mut a, 1).await;
    loop {
        if let Got::Json(v) = next_frame(&mut a).await {
            if v["t"] == "speak_end" {
                break;
            }
        }
    }
    let quiet = tokio::time::timeout(Duration::from_millis(400), async {
        loop {
            if let Some(Ok(m)) = b.next().await {
                if matches!(m, Message::Text(_) | Message::Binary(_)) {
                    return m;
                }
            }
        }
    })
    .await;
    assert!(quiet.is_err(), "second board received {quiet:?}");
}

#[tokio::test]
async fn board_disconnecting_mid_reply_stops_the_run() {
    let brain = FakeBrain::new(&[(0, "Thinking about it. ")], true);
    let st = voiced(brain.clone(), 2000);
    let addr = serve(st).await;
    let (mut ws, _) = connect_voice(addr).await;
    say(&mut ws, 3).await;
    loop {
        if let Got::Json(v) = next_frame(&mut ws).await {
            if v["t"] == "reply_text" || v["t"] == "speak_start" {
                break;
            }
        }
    }
    drop(ws);
    wait_for("the brain stream dropped", || brain.stops.load(Ordering::SeqCst) == 1).await;
}

#[tokio::test]
async fn voice_is_offline_without_backends() {
    let addr = serve(state(1000)).await;
    let (mut ws, mood) = connect_voice(addr).await;
    assert_eq!(mood, json!({"t":"creature","mood":"offline"}));
    send_json(&mut ws, json!({"t":"voice_start","utterance":1})).await;
    assert_eq!(next_json(&mut ws).await, json!({"t":"creature","mood":"offline"}));
}

/// The board never reads, so the socket and the output channel fill up and the writer stalls. A
/// `cancel` must still reach the pipeline: the reader does not wait for the writer.
#[tokio::test]
async fn stalled_writer_does_not_block_cancel() {
    let sentences: Vec<(u64, &str)> = (0..60).map(|_| (0, "This is one sentence of the reply. ")).collect();
    let brain = FakeBrain::new(&sentences, false);
    let st = voiced(brain.clone(), 4 << 20);
    let addr = serve(st).await;
    let (mut ws, _) = connect_voice(addr).await;
    say(&mut ws, 9).await;
    // Let the pipeline run into the full socket and channel.
    wait_for("the brain was asked", || brain.asks.load(Ordering::SeqCst) == 1).await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(brain.stops.load(Ordering::SeqCst), 0, "still running, blocked on the writer");
    send_json(&mut ws, json!({"t":"cancel","utterance":9})).await;
    wait_for("the run was stopped by cancel", || brain.stops.load(Ordering::SeqCst) == 1).await;
}

/// With the board not reading, a flood of control messages and audio must still be dequeued: the voice
/// task is never wedged behind the stalled writer, so the uplink counters return to zero.
#[tokio::test]
async fn voice_task_keeps_draining_the_uplink_while_the_writer_is_stalled() {
    let sentences: Vec<(u64, &str)> = (0..60).map(|_| (0, "This is one sentence of the reply. ")).collect();
    let brain = FakeBrain::new(&sentences, false);
    let st = voiced(brain.clone(), 4 << 20);
    let stats = st.uplink.clone();
    let addr = serve(st).await;
    let (mut ws, _) = connect_voice(addr).await;
    say(&mut ws, 1).await;
    wait_for("the first ask", || brain.asks.load(Ordering::SeqCst) == 1).await;
    // The run speaks into a full socket: the writer is stalled, and a cancel has to close the turn.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    send_json(&mut ws, json!({"t":"cancel","utterance":1})).await;
    for _ in 0..40 {
        send_json(&mut ws, json!({"t":"cancel","utterance":99})).await;
    }
    let frame = encode_audio(99, &[0u8; 4000]);
    for _ in 0..500 {
        ws.send(Message::binary(frame.clone())).await.unwrap();
    }
    send_json(&mut ws, json!({"t":"cancel","utterance":99})).await;
    wait_for("the brain stream was dropped by the cancel", || brain.stops.load(Ordering::SeqCst) == 1).await;
    wait_for("the uplink drained", || {
        stats.queued_audio.load(Ordering::SeqCst) == 0 && stats.queued_control.load(Ordering::SeqCst) == 0
    })
    .await;
    // Still stalled: nothing of this was read by the client.
    assert!(stats.dropped_frames.load(Ordering::SeqCst) < 500 + 41);
}

/// Asserts only the invariant that holds whatever the scheduling: the queue never exceeds its bound.
/// The exact bounds and the drop behaviour are proved in tests/uplink.rs.
#[tokio::test]
async fn audio_uplink_stays_within_the_bound() {
    let brain = FakeBrain::new(&[(0, "Hello. ")], true);
    let st = voiced(brain, 2000);
    let stats = st.uplink.clone();
    let addr = serve(st).await;
    let (mut ws, _) = connect_voice(addr).await;
    send_json(&mut ws, json!({"t":"voice_start","utterance":5})).await;
    let frame = encode_audio(5, &[0u8; 4000]);
    for _ in 0..20000 {
        ws.send(Message::binary(frame.clone())).await.unwrap();
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    let peak = stats.peak_queued_bytes.load(Ordering::SeqCst);
    assert!(peak <= 256 * 1024, "queued {peak} bytes");
}

/// The board's frames are about 3.2 KB; a socket may not make the bridge copy and queue a huge one.
#[tokio::test]
async fn oversize_binary_message_is_rejected() {
    let brain = FakeBrain::new(&[(0, "Hello. ")], true);
    let st = voiced(brain, 2000);
    let stats = st.uplink.clone();
    let addr = serve(st).await;
    let (mut ws, _) = connect_voice(addr).await;
    send_json(&mut ws, json!({"t":"voice_start","utterance":5})).await;
    ws.send(Message::binary(encode_audio(5, &vec![0u8; 200 * 1024]))).await.unwrap();
    let closed = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            match ws.next().await {
                None | Some(Err(_)) | Some(Ok(Message::Close(_))) => return true,
                Some(Ok(_)) => {}
            }
        }
    })
    .await;
    assert_eq!(closed, Ok(true), "the connection stayed open");
    assert_eq!(stats.queued_audio.load(Ordering::SeqCst), 0);
    assert_eq!(stats.peak_queued_bytes.load(Ordering::SeqCst), 0, "the oversize frame was queued");
}
