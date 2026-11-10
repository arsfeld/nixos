//! Due timers delivered to a connected board: a `reminder` card, then the spoken reminder.
//!
//! Time is the timers' `Clock`, an `AtomicI64` the test moves. The tests run on the current-thread
//! runtime, so setting a timer one second ahead and moving the clock past it, with no await in
//! between, means the scheduler next runs with the timer already due: no wall-clock waiting.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

use claude_board_bridge::http::AppState;
use claude_board_bridge::protocol::decode_audio;
use claude_board_bridge::timers::{Clock, REMINDER_GRACE_SECS, Timers, When, rfc3339_local};
use claude_board_bridge::voice::VoiceConfig;
use claude_board_bridge::voice::backends::Backends;
use claude_board_bridge::voice::pipeline::REMINDER_ID_BASE;
use common::{DEVICE_TOKEN, FakeBrain, FakeStt, FakeTts, Ws, next_json, serve, state, try_connect};
use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message;

mod common;

const T0: i64 = 1_794_319_200; // 2026-11-10T09:00:00-05:00

fn timers(path: Option<PathBuf>) -> (Arc<AtomicI64>, Arc<Timers>) {
    let t = Arc::new(AtomicI64::new(T0));
    let c = t.clone();
    let clock: Clock = Arc::new(move || c.load(Ordering::SeqCst));
    (t, Arc::new(Timers::open(path, clock)))
}

fn voiced(brain: Arc<FakeBrain>, tts_bytes: usize, timers: &Arc<Timers>) -> AppState {
    let backends = Backends { stt: FakeStt::new("hello"), tts: Arc::new(FakeTts { bytes: tts_bytes, hang: false }), brain };
    state(1000).with_voice(backends, VoiceConfig::default()).with_timers(timers.clone())
}

/// Sets a timer one second ahead and moves the clock `by` seconds, so it is due `by - 1` seconds late.
fn make_due(clock: &AtomicI64, timers: &Timers, label: &str, by: i64) -> String {
    let t = timers.set(label, When::In(1)).unwrap();
    clock.fetch_add(by, Ordering::SeqCst);
    t.id
}

async fn connect_board(addr: std::net::SocketAddr) -> (Ws, Value) {
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
    ws.send(Message::binary(claude_board_bridge::protocol::encode_audio(id, &[0u8; 3200]))).await.unwrap();
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

/// Every text or binary frame that arrives within `ms`.
async fn quiet_for(ws: &mut Ws, ms: u64) -> Vec<Got> {
    let mut got = Vec::new();
    let _ = tokio::time::timeout(Duration::from_millis(ms), async {
        loop {
            match ws.next().await {
                Some(Ok(Message::Text(t))) => got.push(Got::Json(serde_json::from_str(t.as_str()).unwrap())),
                Some(Ok(Message::Binary(b))) => got.push(Got::Audio(b.to_vec())),
                Some(Ok(_)) => {}
                _ => return,
            }
        }
    })
    .await;
    got
}

fn reminders(got: &[Got]) -> usize {
    got.iter().filter(|g| matches!(g, Got::Json(v) if v["t"] == "reminder")).count()
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
async fn due_timer_reaches_a_connected_board_as_reminder_then_speech() {
    let (clock, timers) = timers(None);
    let addr = serve(voiced(FakeBrain::new(&[], false), 2000, &timers)).await;
    let (mut ws, mood) = connect_board(addr).await;
    assert_eq!(mood, json!({"t":"creature","mood":"idle"}));
    let id = make_due(&clock, &timers, "check the oven", 1);

    let card = next_json(&mut ws).await;
    assert_eq!(card, json!({"t":"reminder","id":id,"label":"check the oven","due":rfc3339_local(T0 + 1)}));
    assert_eq!(next_json(&mut ws).await, json!({"t":"creature","mood":"speaking"}));
    let start = next_json(&mut ws).await;
    assert_eq!(start["t"], "speak_start");
    assert_eq!(start["sample_rate"], 22050);
    let utt = start["utterance"].as_u64().unwrap() as u32;
    assert!(utt >= REMINDER_ID_BASE, "bridge-owned id, got {utt:#x}");
    let mut audio = 0;
    loop {
        match next_frame(&mut ws).await {
            Got::Audio(b) => {
                let (a, pcm) = decode_audio(&b).expect("audio frame");
                assert_eq!(a, utt);
                assert!(!pcm.is_empty());
                audio += 1;
            }
            Got::Json(v) => {
                assert_eq!(v, json!({"t":"speak_end","utterance":utt}));
                break;
            }
        }
    }
    assert!(audio >= 1);
    assert_eq!(next_json(&mut ws).await, json!({"t":"creature","mood":"idle"}));
}

#[tokio::test]
async fn reminder_waits_while_a_reply_is_running() {
    let (clock, timers) = timers(None);
    let brain = FakeBrain::new(&[(0, "Hi there. "), (1000, "Second one.")], false);
    let addr = serve(voiced(brain, 2000, &timers)).await;
    let (mut ws, _) = connect_board(addr).await;
    say(&mut ws, 7).await;
    loop {
        if let Got::Json(v) = next_frame(&mut ws).await {
            if v["t"] == "speak_start" {
                assert_eq!(v["utterance"], 7);
                break;
            }
        }
    }
    make_due(&clock, &timers, "tea", 1);
    let mut tags = Vec::new();
    loop {
        if let Got::Json(v) = next_frame(&mut ws).await {
            let t = v["t"].as_str().unwrap().to_string();
            if t == "speak_end" {
                tags.push(format!("speak_end:{}", v["utterance"]));
            } else if t == "speak_start" {
                let u = v["utterance"].as_u64().unwrap() as u32;
                assert!(u >= REMINDER_ID_BASE);
                tags.push("speak_start:reminder".into());
                break;
            } else {
                tags.push(t);
            }
        }
    }
    let pos = |t: &str| tags.iter().position(|x| x == t).unwrap_or_else(|| panic!("no {t} in {tags:?}"));
    assert!(pos("reminder") < pos("speak_end:7"), "the card arrives at once: {tags:?}");
    assert!(pos("speak_end:7") < pos("speak_start:reminder"), "{tags:?}");
}

#[tokio::test]
async fn reminder_due_with_no_board_is_delivered_on_connect() {
    let (clock, timers) = timers(None);
    let addr = serve(state(1000).with_timers(timers.clone())).await;
    let id = make_due(&clock, &timers, "tea", 30);
    // The scheduler runs and finds no board to claim it.
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(timers.list().len(), 1, "nothing claims it without a board");
    let (mut ws, _) = connect_board(addr).await;
    let card = next_json(&mut ws).await;
    assert_eq!(card["t"], "reminder");
    assert_eq!(card["id"], id);
    assert!(timers.list().is_empty());
}

#[tokio::test]
async fn reminder_past_grace_is_never_delivered() {
    let (clock, timers) = timers(None);
    let addr = serve(state(1000).with_timers(timers.clone())).await;
    make_due(&clock, &timers, "tea", REMINDER_GRACE_SECS + 2);
    let (mut ws, _) = connect_board(addr).await;
    wait_for("the claim dropped it", || timers.list().is_empty()).await;
    assert_eq!(reminders(&quiet_for(&mut ws, 400).await), 0);

    // And with the board already connected when it passes the grace.
    make_due(&clock, &timers, "coffee", REMINDER_GRACE_SECS + 2);
    wait_for("the claim dropped it", || timers.list().is_empty()).await;
    assert_eq!(reminders(&quiet_for(&mut ws, 400).await), 0);
}

#[tokio::test]
async fn two_boards_get_each_reminder_once() {
    let (clock, timers) = timers(None);
    let addr = serve(state(1000).with_timers(timers.clone())).await;
    let (mut a, _) = connect_board(addr).await;
    let (mut b, _) = connect_board(addr).await;
    make_due(&clock, &timers, "one", 1);
    make_due(&clock, &timers, "two", 1);
    let (ga, gb) = tokio::join!(quiet_for(&mut a, 600), quiet_for(&mut b, 600));
    let all: Vec<&Value> = ga.iter().chain(gb.iter()).filter_map(|g| match g {
        Got::Json(v) if v["t"] == "reminder" => Some(v),
        _ => None,
    })
    .collect();
    let mut labels: Vec<&str> = all.iter().map(|v| v["label"].as_str().unwrap()).collect();
    labels.sort();
    assert_eq!(labels, ["one", "two"]);
}

#[tokio::test]
async fn cancel_with_the_bridge_id_stops_reminder_speech() {
    let (clock, timers) = timers(None);
    // 16 MiB of speech is 512 downlink frames: far more than the socket and channel hold.
    let addr = serve(voiced(FakeBrain::new(&[], false), 16 << 20, &timers)).await;
    let (mut ws, _) = connect_board(addr).await;
    make_due(&clock, &timers, "tea", 1);
    let utt = loop {
        if let Got::Json(v) = next_frame(&mut ws).await {
            if v["t"] == "speak_start" {
                break v["utterance"].as_u64().unwrap() as u32;
            }
        }
    };
    send_json(&mut ws, json!({"t":"cancel","utterance":utt})).await;
    let mut audio = 0;
    loop {
        match next_frame(&mut ws).await {
            Got::Audio(_) => audio += 1,
            Got::Json(v) => {
                assert_eq!(v, json!({"t":"speak_end","utterance":utt}));
                break;
            }
        }
    }
    assert!(audio < 512, "the whole reminder was sent ({audio} frames)");
    assert_eq!(next_json(&mut ws).await, json!({"t":"creature","mood":"idle"}));
}

#[tokio::test]
async fn voice_off_still_sends_the_card() {
    let (clock, timers) = timers(None);
    let addr = serve(state(1000).with_timers(timers.clone())).await;
    let (mut ws, mood) = connect_board(addr).await;
    assert_eq!(mood, json!({"t":"creature","mood":"offline"}));
    make_due(&clock, &timers, "tea", 1);
    assert_eq!(next_json(&mut ws).await["t"], "reminder");
    let rest = quiet_for(&mut ws, 700).await;
    assert!(rest.is_empty(), "nothing after the card without voice");
}

#[tokio::test]
async fn claimed_reminder_is_gone_from_the_file() {
    let mut b = [0u8; 6];
    getrandom::fill(&mut b).unwrap();
    let dir = std::env::temp_dir().join(format!("reminders-test-{}", b.iter().map(|x| format!("{x:02x}")).collect::<String>()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("timers.json");
    let (clock, timers) = timers(Some(file.clone()));
    let addr = serve(state(1000).with_timers(timers.clone())).await;
    let (mut ws, _) = connect_board(addr).await;
    let id = make_due(&clock, &timers, "tea", 1);
    assert!(std::fs::read_to_string(&file).unwrap().contains(&id));
    assert_eq!(next_json(&mut ws).await["id"], id);
    let text = std::fs::read_to_string(&file).unwrap();
    assert!(!text.contains(&id), "still in the file: {text}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A refused `voice_start` (here: the per-minute limit is zero) leaves the user still holding, with
/// nothing recording. The reminder's card arrives, but its speech waits for that hold's `voice_end`.
#[tokio::test]
async fn reminder_speech_waits_for_a_refused_hold_to_end() {
    let (clock, timers) = timers(None);
    let backends = Backends {
        stt: FakeStt::new("hello"),
        tts: Arc::new(FakeTts { bytes: 2000, hang: false }),
        brain: FakeBrain::new(&[], false),
    };
    let cfg = VoiceConfig { max_per_minute: 0, ..VoiceConfig::default() };
    let addr = serve(state(1000).with_voice(backends, cfg).with_timers(timers.clone())).await;
    let (mut ws, _) = connect_board(addr).await;
    send_json(&mut ws, json!({"t":"voice_start","utterance":5})).await;
    assert_eq!(next_json(&mut ws).await, json!({"t":"creature","mood":"idle"}), "refused");
    make_due(&clock, &timers, "tea", 1);
    assert_eq!(next_json(&mut ws).await["t"], "reminder");
    // Longer than two reminder ticks.
    let held = quiet_for(&mut ws, 1200).await;
    assert!(held.is_empty(), "something was sent mid-hold: {}", held.len());
    send_json(&mut ws, json!({"t":"voice_end","utterance":5})).await;
    assert_eq!(next_json(&mut ws).await, json!({"t":"creature","mood":"idle"}), "the refusal answered again");
    assert_eq!(next_json(&mut ws).await, json!({"t":"creature","mood":"speaking"}));
    let start = next_json(&mut ws).await;
    assert_eq!(start["t"], "speak_start");
    assert!(start["utterance"].as_u64().unwrap() as u32 >= REMINDER_ID_BASE);
}
