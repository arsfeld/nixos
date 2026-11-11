# Cylon Bot Creature, Step 1: The Voice Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hold the avatar on the board, speak, and hear a spoken reply from a persistent Hermes (DeepSeek) assistant, with the creature's mood following the conversation and an offline state when a backend is down.

**Architecture:** The board streams push-to-talk PCM over its existing websocket to `cylon-bot-bridge`. A new bridge `voice` module transcribes it (whisper.cpp), asks Hermes (HTTP, one fixed session id), synthesises the reply sentence by sentence (Piper) and streams audio back to that one socket. Hermes, whisper.cpp and Piper are loopback services on galactica. Hermes has **no tools** in this step; delegation is step 2 and check-ins are step 3, each with its own plan.

**Tech Stack:** Rust (axum 0.8, tokio, serde, reqwest for loopback HTTP), Slint 1.18 software renderer, ESP-IDF 5.5 C component, NixOS modules, sops-nix, whisper.cpp 1.9.5, Piper 1.8.0, Hermes Agent 0.23.0.

**Spec:** `docs/superpowers/specs/2026-11-10-cylon-bot-creature-design.md`

**Not in this plan (deliberately):** Hermes delegating to Claude Code sessions (step 2); proactive check-ins and quiet hours (step 3); the read-only chat scrollback (only a single last-reply card is built here); wake word; an on-screen keyboard.

## Global Constraints

- Audio uplink: 16 kHz mono PCM16 little-endian, about 100 ms (3200-byte) frames, at most 30 s (`MAX_UTTERANCE_BYTES` = 960 000) per utterance.
- Audio downlink: PCM16 mono at the rate in `speak_start` (Piper's native 22 050 Hz); binary frames at most 32 KiB, because the board drops any websocket frame over 64 KiB without a word (`MAX_FRAME` in `app/src/net.rs`).
- Binary frame layout, both directions: 4-byte little-endian `utterance` id, then PCM bytes.
- Every wire message gets a fixture in `packages/cylon-bot-bridge/tests/fixtures/board/` and a test on both sides; protocol changes go into `packages/cylon-bot-proto`, the fixtures and both test files together.
- `PROTOCOL_VERSION` becomes 3. Boards ignore messages they do not know, so an older board keeps working.
- Voice replies go only to the socket that spoke, never through the `AppState.tx` broadcast.
- Hermes: bound to `127.0.0.1`, one fixed session id (`BRIDGE_HERMES_SESSION`, default `creature`), API key from sops, no tools in this step. Transcripts are logged as lengths and timings only, never text.
- A failing voice backend must never affect approvals or the session feed; the voice module fails on its own.
- Nix: no per-app firewall rules, secrets only through sops (never in `settings` or the store), podman/oci rules per `CLAUDE.md`. Evaluate one host at a time, niced; never build or evaluate `cylon-link`. New files need `git add -N` before `nix build`.
- Commits: conventional (`feat(raider): ...`, `feat(galactica): ...`), straight to `master`, no model or tool names anywhere.
- **Other sessions edit this repo.** At plan time these files had uncommitted changes not made by this work: `firmware/cylon-bot/ui/src/controller.rs`, `ui/tests/{controller,press_tick,render,touch}.rs`, `ui/ui/detail.slint`, `packages/cylon-bot-bridge/src/{board,feed,http}.rs`, `tests/board.rs`, `CLAUDE.md`, and the feed spec. Before each task run `git status`; never stage, revert or fold in changes you did not make. If a task must edit a file with foreign changes, wait until they are committed, or stop and ask.

## Review Focus

Failure modes the spec implies but a straightforward build would miss, each pinned by a test in the task named:

1. The board drops mid-utterance or mid-reply: the buffer must be discarded and the Hermes run stopped, with nothing sent to a dead socket (Task 4, Task 5).
2. Large TTS audio over the 64 KiB frame limit is dropped silently by the board, so a long sentence would go quiet (Task 2 `chunk_pcm`, Task 4).
3. Two boards, or a reconnect: a voice reply must reach only the originating socket (Task 5).
4. Markdown, code blocks, URLs, emoji and decimals in a reply: Piper must get speakable text and the sentence splitter must not cut `3.5` or `e.g.` (Task 2).
5. A short touch must stay a tap (open the session list) and a hold must not also fire a click on release (Task 7).

---

## Gate G1: find the microphone

**Purpose:** the spec's first unverified assumption. Everything in Tasks 8 and 9 depends on the answer.

**Files:**
- Modify: `docs/superpowers/specs/2026-11-10-cylon-bot-creature-design.md` (record the result under "Unverified assumptions")

- [ ] **Step 1:** Read the 1.75C schematic (`https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75C/raw/main/hardware/schematic/ESP32-S3-Touch-AMOLED-1.75C-schematic.pdf`) and the example repo `waveshareteam/ESP32-S3-Touch-AMOLED-1.75C`. Record: the ES7210's I2C address and bus, its I2S data-in pin, whether it shares the ES8311's BCLK/WS/MCLK (GPIO 9/45/42 in `board_display.c`), and whether the mics are analog.
- [ ] **Step 2:** If the board is attached to raider, flash a throwaway build that opens the receive path at 16 kHz for 3 s and logs each 100 ms chunk's RMS, speak near it, and confirm the level rises. If it is not attached, write that this is unverified and leave Task 8's on-device step as the check.
- [ ] **Step 3:** Commit the findings. **Go/no-go:** go if a 16 kHz capture path is identified. No-go stops Tasks 8 and 9; report to the user.

```bash
git add docs/superpowers/specs/2026-11-10-cylon-bot-creature-design.md
git commit -m "docs(raider): record where the board's microphone lives"
```

## Gate G2: a tool-less Hermes with an events stream

**Purpose:** spec assumption 2, and the shape of the run events the bridge parses.

**Files:**
- Modify: the same spec, under "Unverified assumptions"

- [ ] **Step 1:** In a scratch `HERMES_HOME` on raider (the spike procedure: copy only `config.yaml`, `auth.json` and the `DEEPSEEK_API_KEY` line, ask the user first, delete the scratch home afterwards), find a configuration under which the API server exposes **no tools**. Candidates from the docs: `agent.disabled_toolsets`, `hermes tools --platform api_server`, a `toolsets:` key. Hermes allows one gateway per host: stop the scratch gateway first.
- [ ] **Step 2:** Prove it. With the API server up, ask it to "run `echo pwned` in a shell and tell me the output" and to "read /etc/hostname". Pass only if it reports it cannot, and `GET /v1/toolsets` (or the equivalent) lists nothing executable.
- [ ] **Step 3:** Drive one run: `POST /v1/runs`, read `GET /v1/runs/{id}/events` (SSE) to the end, and `POST /v1/runs/{id}/stop` on a second run mid-stream. Record the exact event names and JSON shapes (the text delta event, the final event), and the `X-Hermes-Session-Id` handling for runs.
- [ ] **Step 4:** Decide how Hermes is deployed on galactica (Hermes' NixOS module, or a pinned container) and record why. Commit.

**Go/no-go:** if no tool-less configuration can be proven, stop. Do not proceed with Hermes holding a shell behind a public, token-gated endpoint; report to the user.

```bash
git add docs/superpowers/specs/2026-11-10-cylon-bot-creature-design.md
git commit -m "docs(raider): record how to run Hermes without tools and its run events"
```

## Gate G3: speech latency and serving interfaces on galactica

**Files:**
- Modify: the same spec, under "Unverified assumptions"

- [ ] **Step 1:** On galactica, with `nix run`/`nix shell` from nixpkgs (not installed), measure whisper.cpp on a recorded 5 s utterance with `ggml-base.en` and `ggml-small.en`: wall time and the transcript. Measure Piper's time to produce the first sentence of a 40-word reply with one en_US voice.
- [ ] **Step 2:** Find how each is served over loopback HTTP: whisper.cpp's server binary and its request/response shape; Piper's HTTP server (or a small wrapper) and its response format and sample rate. Record both exactly.
- [ ] **Step 3:** Pick the models. Targets: transcription of 5 s of speech in at most 2 s, and Piper's first sentence in at most 1 s. If `small.en` misses the target, use `base.en` and say so. Commit.

```bash
git add docs/superpowers/specs/2026-11-10-cylon-bot-creature-design.md
git commit -m "docs(raider): record whisper and piper latency and serving on galactica"
```

---

### Task 1: Voice messages in the proto crate

**Files:**
- Modify: `packages/cylon-bot-proto/src/lib.rs`, `packages/cylon-bot-proto/src/model.rs` (every match over `BoardMsg` that is now non-exhaustive)
- Create: fixtures `creature.json`, `transcript.json`, `reply_text.json`, `speak_start.json`, `speak_end.json` in `packages/cylon-bot-bridge/tests/fixtures/board/`
- Modify: `packages/cylon-bot-bridge/src/protocol.rs` (re-export the new items)
- Test: inline tests in `packages/cylon-bot-proto/src/lib.rs`

**Interfaces:**
- Produces, in `cylon_bot_proto`:
  - `pub const PROTOCOL_VERSION: u32 = 3;`
  - `pub const UPLINK_RATE: u32 = 16_000;` and `pub const MAX_UTTERANCE_BYTES: usize = 960_000;` and `pub const AUDIO_HEADER_LEN: usize = 4;` and `pub const DOWNLINK_CHUNK_MAX: usize = 32 * 1024;`
  - `pub enum Mood { Listening, Thinking, Speaking, Alert, Offline, #[serde(other)] Idle }` (lowercase, same pattern as `State`)
  - `BoardMsg::Creature { mood: Mood }`, `BoardMsg::Transcript { utterance: u32, text: String }`, `BoardMsg::ReplyText { utterance: u32, text: String }`, `BoardMsg::SpeakStart { utterance: u32, sample_rate: u32 }`, `BoardMsg::SpeakEnd { utterance: u32 }`
  - `ClientMsg::VoiceStart { utterance: u32 }`, `ClientMsg::VoiceEnd { utterance: u32 }`, `ClientMsg::Cancel { utterance: u32 }`
  - `pub fn encode_audio(utterance: u32, pcm: &[u8]) -> Vec<u8>` and `pub fn decode_audio(frame: &[u8]) -> Option<(u32, &[u8])>` (`None` only when the frame is shorter than the header; an empty payload is valid)

- [ ] **Step 1: Write the failing tests** in `lib.rs`: `audio_frame_round_trips` (`decode_audio(&encode_audio(7, &[1,2,3,4]))` is `Some((7, &[1,2,3,4]))`); `audio_frame_shorter_than_header_is_none`; `empty_audio_payload_is_valid`; `voice_client_messages_serialise_to_the_firmware_shape` (assert `{"t":"voice_start","utterance":3}`, `{"t":"voice_end","utterance":3}`, `{"t":"cancel","utterance":3}`); `unknown_mood_parses_as_idle`. The existing `every_board_fixture_round_trips_through_boardmsg` test must pick up the five new fixtures; raise its `n >= 10` floor to 15.
- [ ] **Step 2:** Run `nix build .#cylon-bot-proto` and see the new tests fail to compile.
- [ ] **Step 3:** Implement the items above and the five fixtures (one realistic message each, `utterance` 3, `sample_rate` 22050, mood `thinking`, transcript `"what is on my calendar"`). Extend `PROTOCOL_VERSION`'s doc comment: "Version 3 adds the creature's voice messages."
- [ ] **Step 4:** Fix every non-exhaustive match in `model.rs` (new `BoardMsg` variants are not model state: they apply as `Applied::Ignored` or the crate's existing "nothing changed" outcome). Run `nix build .#cylon-bot-proto` and see it pass.
- [ ] **Step 5:** Commit.

```bash
git add packages/cylon-bot-proto packages/cylon-bot-bridge/src/protocol.rs packages/cylon-bot-bridge/tests/fixtures
git commit -m "feat(raider): add the creature's voice messages to the board protocol"
```

### Task 2: Speakable text and audio chunking (pure functions)

**Files:**
- Create: `packages/cylon-bot-bridge/src/voice/mod.rs` (declares `speech`, re-exports), `packages/cylon-bot-bridge/src/voice/speech.rs`
- Modify: `packages/cylon-bot-bridge/src/lib.rs` (`pub mod voice;`)
- Test: `packages/cylon-bot-bridge/tests/speech.rs`

**Interfaces:**
- Produces:
  - `pub fn clean_for_speech(text: &str) -> String`: drops fenced code blocks entirely, removes inline-code backticks and markdown markers (`#`, `*`, `_`, `>`), replaces a URL with `link`, removes emoji and other non-speakable symbols, collapses whitespace.
  - `pub struct SentenceSplitter` with `pub fn new() -> SentenceSplitter`, `pub fn push(&mut self, delta: &str) -> Vec<String>` (completed sentences, cleaned), `pub fn finish(&mut self) -> Option<String>` (the trailing fragment).
  - `pub fn chunk_pcm(pcm: &[u8], max: usize) -> impl Iterator<Item = &[u8]>`: every chunk has even length (never splits a 16-bit sample) and at most `max` bytes.

- [ ] **Step 1: Write the failing tests** (names and assertions): `splitter_cuts_at_sentence_ends` (`push("Hello there. How are you? Fine")` returns `["Hello there.", "How are you?"]`, `finish()` is `Some("Fine")`); `splitter_does_not_cut_decimals_or_abbreviations` (`"Pi is 3.14 today, e.g. now."` stays one sentence); `splitter_joins_deltas_split_mid_word`; `splitter_ignores_empty_and_whitespace_only_input`; `clean_drops_code_blocks_and_keeps_inline_code_text`; `clean_replaces_urls_with_link`; `clean_removes_emoji_and_markdown_markers`; `chunk_pcm_never_splits_a_sample_and_respects_max` (odd `max` of 5 gives chunks of 4); `chunk_pcm_of_empty_input_yields_nothing`.
- [ ] **Step 2:** Run `cargo test -p cylon-bot-bridge --test speech` from `packages/cylon-bot-bridge` inside `nix develop` and see compile failures.
- [ ] **Step 3:** Implement. The splitter holds a buffer and cuts at `.`, `!`, `?` or a newline followed by whitespace or end of input, skipping a `.` between digits and after the abbreviations `e.g.`, `i.e.`, `vs.`, `Dr.`, `Mr.`, `Mrs.`; a fragment under 8 characters carries into the next sentence.
- [ ] **Step 4:** Run the tests and see them pass.
- [ ] **Step 5:** Commit.

```bash
git add packages/cylon-bot-bridge/src/voice packages/cylon-bot-bridge/src/lib.rs packages/cylon-bot-bridge/tests/speech.rs
git commit -m "feat(raider): turn replies into speakable sentences and audio chunks"
```

### Task 3: Voice backends (speech-to-text, text-to-speech, Hermes)

**Files:**
- Create: `packages/cylon-bot-bridge/src/voice/backends.rs`
- Modify: `packages/cylon-bot-bridge/Cargo.toml` (add `reqwest = { version = "0.12", default-features = false, features = ["json", "stream", "multipart"] }`; loopback is plain HTTP so no TLS), `packages/cylon-bot-bridge/Cargo.lock`, `packages/cylon-bot-bridge/src/voice/mod.rs`
- Test: `packages/cylon-bot-bridge/tests/backends.rs` (fake HTTP servers built with axum on `127.0.0.1:0`, shaped exactly as recorded in G2 and G3)

**Interfaces:**
- Produces:
  - `pub enum VoiceError { Unavailable(String), Timeout, Rejected(String) }`
  - `pub struct Speech { pub sample_rate: u32, pub pcm: Vec<u8> }`
  - `pub struct Reply { pub deltas: BoxStream<'static, Result<String, VoiceError>> }`: dropping a `Reply` before it ends must stop the Hermes run (a guard that spawns `POST /v1/runs/{id}/stop`).
  - `pub trait Stt: Send + Sync { fn transcribe(&self, pcm16k: Vec<u8>) -> BoxFuture<'static, Result<String, VoiceError>>; }`
  - `pub trait Tts: Send + Sync { fn synthesize(&self, text: String) -> BoxFuture<'static, Result<Speech, VoiceError>>; }`
  - `pub trait Brain: Send + Sync { fn ask(&self, text: String) -> BoxFuture<'static, Result<Reply, VoiceError>>; }`
  - `pub struct Backends { pub stt: Arc<dyn Stt>, pub tts: Arc<dyn Tts>, pub brain: Arc<dyn Brain> }`
  - `pub struct WhisperHttp::new(base_url: String)`, `pub struct PiperHttp::new(base_url: String)`, `pub struct HermesHttp::new(base_url: String, api_key: String, session_id: String)`, each implementing its trait; `BoxFuture`/`BoxStream` come from `futures_util`.

- [ ] **Step 1: Write the failing tests** against fake servers: `whisper_returns_the_transcript` (fake returns the recorded JSON; the PCM is sent as a WAV with a 16 kHz header); `whisper_error_status_is_unavailable`; `piper_returns_pcm_and_rate`; `hermes_streams_deltas_in_order` (fake SSE emits three delta events then the final event; assert the three strings); `hermes_sends_bearer_key_and_session_header` (fake records the headers; assert `Authorization: Bearer <key>` and the session id header recorded in G2); `dropping_a_reply_stops_the_run` (fake counts calls to the stop path; assert one call within 1 s of the drop); `unreachable_backend_is_unavailable_not_a_panic` (connect to a closed port).
- [ ] **Step 2:** Run the tests and see them fail.
- [ ] **Step 3:** Implement the three HTTP clients, with a 15 s connect and 60 s overall request timeout on STT and TTS, mapping connect errors to `Unavailable` and timeouts to `Timeout`. Parse Hermes' event stream with the event names recorded in G2, ignoring events it does not know.
- [ ] **Step 4:** Run the tests and see them pass. Run `nix build .#cylon-bot-bridge` (the Nix build runs `cargo test`; if the vendored hash is rejected, update it as Nix reports).
- [ ] **Step 5:** Commit.

```bash
git add packages/cylon-bot-bridge/Cargo.toml packages/cylon-bot-bridge/Cargo.lock packages/cylon-bot-bridge/src/voice packages/cylon-bot-bridge/tests/backends.rs
git commit -m "feat(raider): add the whisper, piper and hermes clients to the bridge"
```

### Task 4: The per-connection voice pipeline

**Files:**
- Create: `packages/cylon-bot-bridge/src/voice/pipeline.rs`
- Modify: `packages/cylon-bot-bridge/src/voice/mod.rs`
- Test: `packages/cylon-bot-bridge/tests/pipeline.rs` (in-process fakes implementing the three traits; no sockets)

**Interfaces:**
- Consumes: Task 1 messages, Task 2 `clean_for_speech`/`SentenceSplitter`/`chunk_pcm`, Task 3 `Backends` and traits.
- Produces:
  - `pub enum Out { Json(BoardMsg), Audio(Vec<u8>) }` (`Audio` already carries the 4-byte header)
  - `pub struct VoiceConfig { pub reply_timeout: Duration, pub max_per_minute: u32 }` with `Default` of 60 s and 10
  - `pub struct Conn` with `pub fn new(backends: Option<Arc<Backends>>, cfg: VoiceConfig, out: tokio::sync::mpsc::Sender<Out>) -> Conn`, `pub async fn on_client(&mut self, msg: &ClientMsg)` (handles `VoiceStart`, `VoiceEnd`, `Cancel`; ignores the rest) and `pub fn on_audio(&mut self, frame: &[u8])`. Dropping a `Conn` aborts any run, discards the buffer and drops the reply (which stops Hermes).
- Behaviour to implement: `new` with `None` backends makes `VoiceStart` send `Creature{Offline}` and ignore audio. Happy path emits, in order: `Creature{Thinking}`, `Transcript`, `ReplyText` (full reply, once), `Creature{Speaking}`, `SpeakStart`, audio frames (each at most `DOWNLINK_CHUNK_MAX`, header included), `SpeakEnd`, `Creature{Idle}`. Sentences are synthesised as they complete, so the first audio can precede the end of the reply. An utterance over `MAX_UTTERANCE_BYTES`, an audio frame for the wrong utterance id, or a frame too short for the header, is dropped. An empty transcript sends `Creature{Idle}` and calls no brain. A second `VoiceStart` while one is running cancels the first. After `max_per_minute` utterances in a rolling minute, `VoiceStart` is refused with `Creature{Idle}`. The bridge logs one line per utterance: `voice: utt=<n> bytes=<n> stt_ms=<n> first_delta_ms=<n> first_audio_ms=<n> total_ms=<n>` and never the text.

- [ ] **Step 1: Write the failing tests**: `happy_path_emits_the_messages_in_order`; `first_audio_arrives_before_the_reply_ends` (fake brain delays its second sentence); `no_backends_reports_offline`; `empty_transcript_calls_no_brain`; `stt_failure_reports_offline_and_returns_to_idle_later` (offline, then idle on the next successful utterance); `brain_timeout_stops_the_run_and_returns_to_idle` (fake brain never ends; `reply_timeout` of 50 ms; assert the stop guard fired); `cancel_aborts_speech_and_stops_the_run` (Review Focus 1); `dropping_conn_mid_reply_stops_the_run_and_sends_nothing_more` (Review Focus 1); `audio_chunks_never_exceed_the_frame_limit` for a 200 KB synthetic reply (Review Focus 2); `oversize_utterance_is_dropped`; `wrong_utterance_id_audio_is_ignored`; `eleventh_utterance_in_a_minute_is_refused`.
- [ ] **Step 2:** Run `cargo test -p cylon-bot-bridge --test pipeline` and see them fail.
- [ ] **Step 3:** Implement `Conn`. One tokio task per utterance holds the `Reply`; its `JoinHandle` is aborted on cancel and on drop. Use `tokio::time::pause` in tests for the timeout and rate window.
- [ ] **Step 4:** Run the tests and see them pass.
- [ ] **Step 5:** Commit.

```bash
git add packages/cylon-bot-bridge/src/voice packages/cylon-bot-bridge/tests/pipeline.rs
git commit -m "feat(raider): run an utterance from the board through speech and hermes and back"
```

### Task 5: Wire the pipeline into the board socket and the bridge's configuration

**Files:**
- Modify: `packages/cylon-bot-bridge/src/board.rs` (foreign edits at plan time: see Global Constraints), `packages/cylon-bot-bridge/src/http.rs` (`AppState`), `packages/cylon-bot-bridge/src/main.rs`
- Create: `packages/cylon-bot-bridge/tests/common/mod.rs` (the websocket helpers now duplicated in `tests/board.rs`: `serve`, `try_connect`, `connect`, `next_json`), `packages/cylon-bot-bridge/tests/voice.rs`
- Modify: `packages/cylon-bot-bridge/tests/board.rs` to use `tests/common`, **only** once its foreign edits are committed

**Interfaces:**
- Consumes: Task 4 `Conn`, `Out`, `VoiceConfig`; Task 3 `Backends`.
- Produces: `AppState::with_voice(self, backends: Backends, cfg: VoiceConfig) -> AppState`; `AppState` gains `voice: Option<Arc<Backends>>` and `voice_cfg: VoiceConfig`. Environment read in `main.rs` (documented in its header comment, in the existing style): `BRIDGE_STT_URL`, `BRIDGE_TTS_URL`, `BRIDGE_HERMES_URL`, `BRIDGE_HERMES_KEY_FILE`, `BRIDGE_HERMES_SESSION` (default `creature`), `BRIDGE_REPLY_TIMEOUT_SECS` (default 60). Voice is enabled only when all of the first four are set; otherwise it is off and the board sees `Creature{Offline}` on `voice_start`.

- [ ] **Step 1: Write the failing tests** in `tests/voice.rs` over a real websocket with in-process fake backends: `voice_round_trip_over_the_socket` (send `voice_start`, binary frames, `voice_end`; read `creature`, `transcript`, `reply_text`, `speak_start`, at least one binary frame that `decode_audio`s to the right utterance, `speak_end`); `voice_reply_reaches_only_the_speaking_socket` (two boards connected, only the first receives voice messages; Review Focus 3); `board_disconnecting_mid_reply_stops_the_run`; `voice_is_offline_without_backends`; `existing_board_tests_still_pass` is the existing suite, run unchanged.
- [ ] **Step 2:** Run `cargo test -p cylon-bot-bridge --test voice` and see it fail.
- [ ] **Step 3:** In `serve` (board.rs), create an `mpsc::channel::<Out>(64)` and a `Conn` per socket; add an `out_rx.recv()` arm to the select that sends `Out::Json` as text and `Out::Audio` as `Message::Binary`; pass `Message::Binary(b)` to `conn.on_audio` and the three voice `ClientMsg`s to `conn.on_client`. Send `Creature{Idle}` after the snapshot when voice is enabled, `Creature{Offline}` when not.
- [ ] **Step 4:** Implement `with_voice` and the `main.rs` environment handling. Run the full bridge suite (`cargo test` in `packages/cylon-bot-bridge`) and `nix build .#cylon-bot-bridge`; all must pass.
- [ ] **Step 5:** Commit.

```bash
git add packages/cylon-bot-bridge
git commit -m "feat(raider): serve the creature's voice over the board socket"
```

### Task 6: Run Hermes, whisper and piper on galactica

**Files:**
- Create: `modules/hosts/galactica/services/cylon-bot-voice.nix` (a flake-parts module defining `configurations.nixos.galactica.module`, in the style of `cylon-bot.nix`), `modules/hosts/galactica/services/_creature/SOUL.md` (a `/_` path, so import-tree does not load it)
- Modify: `secrets/sops/galactica.yaml` (add `hermes-api-key`, `deepseek-api-key`, set with `sops --set`, never interactively)

**Interfaces:**
- Consumes: the deployment choice from G2, the serving interfaces and models from G3, and the bridge environment names from Task 5.
- Produces: loopback services for whisper.cpp, Piper and Hermes; `systemd.services.cylon-bot.environment` entries `BRIDGE_STT_URL`, `BRIDGE_TTS_URL`, `BRIDGE_HERMES_URL`, `BRIDGE_HERMES_KEY_FILE = "%d/hermes-key"` and a `LoadCredential` entry `"hermes-key:${config.sops.secrets.hermes-api-key.path}"` (the lists merge with `cylon-bot.nix`). Hermes' own environment file carries `DEEPSEEK_API_KEY` and its API key, via sops, never `settings`. `SOUL.md` is installed into Hermes' state dir.
- `SOUL.md` content decisions: the creature answers in one or two plain sentences with no markdown, lists, code or emoji (its words are spoken); says so when it does not know; has no tools and does not claim to act on the machine; its name is the first line of the file so the user can change it (default: `Claude`).

- [ ] **Step 1:** Write the module. Services start `after`/`wants` as needed, bind to `127.0.0.1` only, run as dynamic users with the hardening set `cylon-bot.nix` uses where the software allows, and add no firewall rules.
- [ ] **Step 2:** `git add -N` the new files, then `nice nix build .#nixosConfigurations.galactica.config.system.build.toplevel`. Expected: it builds. Run it for galactica only.
- [ ] **Step 3:** Run `just fmt`, then `nix build .#nixosConfigurations.galactica.config.system.build.toplevel` again and confirm no change.
- [ ] **Step 4:** Commit. **Do not deploy.** Deployment is Task 10 and needs the user's go.

```bash
git add modules/hosts/galactica/services/cylon-bot-voice.nix modules/hosts/galactica/services/_creature secrets/sops/galactica.yaml
git commit -m "feat(galactica): run whisper, piper and a tool-less hermes for the board's creature"
```

### Task 7: Hold to talk, creature moods and the reply card (UI crate)

**Files:**
- Modify: `firmware/cylon-bot/ui/src/touch.rs`, `ui/src/controller.rs` (foreign edits at plan time), `ui/ui/home.slint`, `ui/ui/app.slint`, `ui/ui/theme.slint` if a new property type is needed
- Test: `ui/src/touch.rs` inline tests, `ui/tests/controller.rs`, `ui/tests/render.rs`

**Interfaces:**
- Produces:
  - `touch::Gesture` gains `HoldStart(i16, i16)` and `HoldEnd` (still `Copy + Eq`); `TouchTracker::update_at(&mut self, x: i16, y: i16, pressed: bool, now_ms: u64) -> Update`; the existing `update` stays and calls it with a clock that never reaches the threshold. A finger held for `HOLD_MS = 450` within `HOLD_SLOP_PX = 20` of where it landed emits `HoldStart` once and cancels the pointer (`PointerExited`), so no click follows; the lift emits `HoldEnd`. Movement beyond the slop before the threshold cancels hold detection.
  - `Outbox` gains `fn send_bin(&self, bytes: Vec<u8>) -> bool { false }` (default, so existing implementors are untouched).
  - `Controller::hold_started(&self, x: i16, y: i16) -> bool`: true only on `Page::Home` when `(x, y)` is within the avatar; it then shows `PresenceState::Listening`, allocates the next utterance id, sends `VoiceStart`, and the app starts the microphone. `Controller::hold_ended(&self) -> Option<u32>`: sends `VoiceEnd`, returns the utterance id; `Controller::utterance(&self) -> Option<u32>`; `Controller::set_mic_level(&self, level: f32)` drives `presence-level`; `Controller::tap_cancels_speech`, an internal rule: a tap anywhere while speaking sends `Cancel` and returns to idle.
  - The controller applies bridge `Creature{mood}` to `presence-state` (`Offline` shows idle presence plus a new `voice-available: bool` property set false, shown as a small "voice offline" note on home), `Transcript` (kept for the reply card's heading) and `ReplyText` into a new `reply-text: string` property. The card shows the last reply under the avatar for 20 s of `tick_at` time, or until tapped.

- [ ] **Step 1: Write the failing tests**: in `touch.rs`: `a_short_touch_is_still_a_tap` (Review Focus 5: press, release at 200 ms, no gesture, normal press and release events); `a_long_touch_emits_holdstart_once_and_no_click` (press, samples to 600 ms, exactly one `HoldStart`, then `PointerExited`, and no `PointerReleased` on lift, one `HoldEnd`); `moving_before_the_threshold_is_not_a_hold`; `a_swipe_is_not_a_hold`. In `controller.rs` tests: `hold_on_the_avatar_sends_voice_start_and_shows_listening`; `hold_off_the_avatar_does_nothing`; `release_sends_voice_end_with_the_same_utterance`; `creature_thinking_and_speaking_set_the_presence_state`; `offline_mood_sets_voice_unavailable`; `reply_text_shows_the_card_and_it_expires_after_20_seconds`; `tapping_while_speaking_sends_cancel`; `a_hold_during_a_waiting_question_is_ignored` (the question owns the screen).
- [ ] **Step 2:** Run `nix develop .#firmware -c bash -c 'cd firmware/cylon-bot && cargo test -p cylon-bot-ui'` and see the new tests fail to compile or fail.
- [ ] **Step 3:** Implement the tracker, then the controller, then the Slint properties and the card (a text card under the avatar in the existing theme; ASCII plus the existing glyph set, per `ui/glyphs.slint`).
- [ ] **Step 4:** Add render tests in `ui/tests/render.rs` for the listening, thinking and speaking presence and for the reply card with a two-sentence reply; run `just board preview` and look at the PNGs in `firmware/cylon-bot/preview/` for overlap and legibility.
- [ ] **Step 5:** Run the full UI test suite and see it pass. Commit.

```bash
git add firmware/cylon-bot/ui
git commit -m "feat(raider): hold the avatar to talk and show the creature's moods and replies"
```

### Task 8: Microphone capture and uplink (firmware)

**Depends on Gate G1.**

**Files:**
- Modify: `firmware/cylon-bot/app/components/board_display/board_display.c`, `board_display.h`, `idf_component.yml` only if the ES7210 driver needs declaring, `firmware/cylon-bot/app/src/display.rs`, `app/src/net.rs`, `app/src/main.rs`
- Create: `firmware/cylon-bot/app/src/mic.rs`

**Interfaces:**
- Consumes: the pins, address and format recorded in G1; `cylon_bot_proto::{encode_audio, UPLINK_RATE, MAX_UTTERANCE_BYTES}`; Task 7 `hold_started`, `hold_ended`, `utterance`, `set_mic_level`.
- Produces: C `esp_err_t bd_mic_open(uint32_t rate_hz)`, `int bd_mic_read(int16_t *out, int max_samples, uint32_t timeout_ms)` (samples read, negative on error), `void bd_mic_close(void)`; Rust `display::mic_open() -> anyhow::Result<()>`, `display::mic_read(&mut [i16]) -> usize`, `display::mic_close()`; `Net::send_bin` implementing `Outbox::send_bin` through `esp_websocket_client_send_bin`; `mic::Capture::start(utterance: u32, net: Net, levels: mpsc::Sender<f32>) -> Capture` and `Capture::stop(self)`. The capture thread reads 1600-sample (100 ms) chunks, sends each as `encode_audio(utterance, bytes)`, reports each chunk's normalised RMS to `levels`, and stops by itself after `MAX_UTTERANCE_BYTES` or on a failed send (then the app sends `Cancel`).
- The mic buffers live in PSRAM; the transmit chunk is a stack or heap `Vec` freed per chunk, not a growing buffer.

- [ ] **Step 1: Write the failing host test** for the one pure piece: `audio::rms_level(&[i16]) -> f32` (silence is 0.0, a full-scale square wave is about 1.0, always within 0 to 1) and `audio::chunk_to_frame(utterance: u32, &[i16]) -> Vec<u8>` (little-endian samples behind the 4-byte header, decodable with `decode_audio`). Put them in `cylon-bot-ui` (`ui/src/audio.rs`) so `cargo test -p cylon-bot-ui` covers them; `mic.rs` calls them.
- [ ] **Step 2:** Run the UI tests and see them fail; implement `audio.rs`; see them pass.
- [ ] **Step 3:** Implement the C functions to the G1 findings (ES7210 via `esp_codec_dev` where the managed component provides it), the Rust wrappers, `Net::send_bin`, and `mic.rs`. In `main.rs`, handle `Gesture::HoldStart`/`HoldEnd` from the platform layer (add `platform::take_hold_start()`/`take_hold_end()` next to `take_swipe_right`): start `Capture` when `controller.hold_started` returns true, stop it on `HoldEnd`, call `controller.set_mic_level` from the levels channel.
- [ ] **Step 4:** `just board build` (see `just board --list` first). Expected: it builds. If the board is attached: `just board flash` and `just board monitor`, hold the avatar and speak, and confirm the log shows chunks sent and the avatar's ring responds; confirm the bridge (Task 5, run locally with fake backends or deployed) receives `voice_start`, frames and `voice_end`. If not attached, say the on-device check is pending.
- [ ] **Step 5:** Check the `heap:` log line before and during a hold: internal free memory must not drop by more than 16 KB. Commit.

```bash
git add firmware/cylon-bot
git commit -m "feat(raider): capture the microphone and stream it to the bridge"
```

### Task 9: Spoken replies: downlink audio, playback and cancel (firmware)

**Files:**
- Modify: `firmware/cylon-bot/app/components/board_display/board_display.c`, `board_display.h`, `app/src/display.rs`, `app/src/net.rs`, `app/src/main.rs`
- Create: `firmware/cylon-bot/ui/src/audio.rs` additions (the playback state machine), `app/src/speaker.rs`
- Test: `ui/src/audio.rs` inline tests

**Interfaces:**
- Consumes: Task 7 `Controller` (`Creature`, `SpeakStart`, `SpeakEnd` arrive through `on_message`); the proto binary frame format.
- Produces:
  - `ui::audio::Playback` (pure state machine): `new() -> Playback`, `begin(&mut self, utterance: u32, rate: u32)`, `push(&mut self, frame: &[u8])` (decodes the header; ignores a frame for another utterance or too short), `end(&mut self)`, `stop(&mut self)`, `next_chunk(&mut self) -> Option<Vec<u8>>`, `rate(&self) -> Option<u32>`, `is_idle(&self) -> bool`.
  - `net::Event::Audio(Vec<u8>)` for complete binary frames (op code 0x2), within the existing 64 KiB `MAX_FRAME`.
  - C `esp_err_t bd_speaker_begin(uint32_t rate_hz)`, `int bd_speaker_write(const void *pcm, size_t bytes)`, `void bd_speaker_end(void)` (the existing chime opens and closes the same codec handle: it must not run while speaking, so `bd_chime` returns early when a stream is open); `speaker::Player` running `next_chunk` into `bd_speaker_write` on its own thread so the UI loop never blocks; `Player::stop()` flushes and closes immediately.

- [ ] **Step 1: Write the failing tests** for `Playback`: `chunks_come_out_in_order`; `audio_for_another_utterance_is_ignored`; `a_frame_shorter_than_the_header_is_ignored`; `stop_discards_queued_audio_and_goes_idle`; `end_lets_queued_audio_drain_before_idle`; `begin_for_a_new_utterance_replaces_an_old_one`.
- [ ] **Step 2:** Run the UI tests and see them fail; implement `Playback`; see them pass.
- [ ] **Step 3:** Extend `handle_data` in `net.rs` for binary frames; implement the C speaker stream and `speaker.rs`; in `main.rs` feed `SpeakStart`/`Audio`/`SpeakEnd` to `Playback`/`Player` and stop playback when the controller cancels (a tap while speaking) or the link drops.
- [ ] **Step 4:** `just board build`. If the board is attached: flash, run a full exchange (deployed bridge or local fakes), confirm the reply is audible, a tap mid-sentence stops it at once, and the log's `heap:` line shows no leak across five exchanges.
- [ ] **Step 5:** Commit.

```bash
git add firmware/cylon-bot
git commit -m "feat(raider): play the creature's spoken replies and stop them on a tap"
```

### Task 10: Documentation, deployment and the acceptance run

**Files:**
- Modify: `CLAUDE.md` (the Cylon Bot section; foreign edits at plan time: see Global Constraints), the creature spec (record measured numbers)

- [ ] **Step 1:** Update `CLAUDE.md`: voice path, the new services and secrets, the environment variables, the hold gesture, the traps found (mic hardware, the 64 KiB frame limit, Hermes tool-less configuration, one gateway per host), and `just` recipes if any were added. Keep it in the file's existing style.
- [ ] **Step 2:** Ask the user before deploying. On their go, `just deploy galactica` (phase 1 needs raider; see `CLAUDE.md`), then check `systemctl --failed` on galactica and `journalctl -u cylon-bot -n 20` for `voice:` timing lines.
- [ ] **Step 3: Acceptance run on the real board:** ten spoken exchanges. Pass when: every one gets a spoken reply; median time from releasing the avatar to the first spoken word is at most 5 s (a target this plan sets because the spec names none; confirm or change it); a tap mid-reply stops speech within 1 s; taking Hermes down (`systemctl stop`) shows the offline note and approvals still work; restarting `cylon-bot` while the board is up reconnects and returns to idle.
- [ ] **Step 4:** Record the measured median and worst case in the spec and commit.

```bash
git add CLAUDE.md docs/superpowers/specs/2026-11-10-cylon-bot-creature-design.md
git commit -m "docs(raider): document the creature's voice path and its measured latency"
```
