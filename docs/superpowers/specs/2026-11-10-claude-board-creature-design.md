# Claude Board creature: a voice companion that runs your Claude sessions

Date: 2026-11-10. Status: design, awaiting review.

## Goal

Turn the Claude Board (ESP32-S3 AMOLED, `firmware/claude-board`) into a Tamagotchi-style
companion. The avatar becomes a creature you talk to by voice. It is the front end of one
persistent assistant that remembers you and starts, steers and reports on Claude Code sessions
across the fleet.

Phase 1 of the board (status and answering questions) is built. This is the "phase 2" the board
docs left open: voice, and starting sessions.

## Decisions

| Question | Decision |
|---|---|
| Who is the creature? | One persistent **Hermes Agent** (Nous Research, MIT) session, not a fresh Claude session per chat |
| Model | **DeepSeek** (`deepseek-v4-flash`), as the existing Hermes on raider already runs |
| Where Hermes runs | **galactica**, loopback only |
| Authority | **Delegate only.** Hermes has no shell or file tools. It can start, steer and read Claude Code sessions. Their work is gated by the existing board Allow/Deny approvals |
| I/O | **Full voice both ways**, with a text card for each reply |
| Voice stack | **Local on galactica**: whisper.cpp (STT) and Piper (TTS) |
| Activation | **Tap-and-hold the avatar** (push-to-talk). No wake word |
| Idle behavior | Mood and reactions, plus **proactive check-ins** |
| Interrupts | **Visual first.** Spoken only when urgent, never in quiet hours |
| Where the glue lives | **Extend `claude-board-bridge`** with a voice module |

## Architecture

```
board (ESP32) --wss: audio--> bridge (galactica) --> whisper.cpp (STT)
                                  |--> Hermes (127.0.0.1) --> Claude Code sessions
board <--wss: text, mood, audio-- bridge <-- Piper (TTS)
```

### Board

- Hold the avatar: record the mic and stream it. Release sends the utterance.
- Show replies as text and play the spoken reply.
- Avatar mood is driven by the bridge. Tap still opens the session list.
- Touching the screen while the creature speaks cancels the reply.

### Bridge (new voice module)

- Buffers an utterance, transcribes it, and sends the text to Hermes under one fixed
  `X-Hermes-Session-Id`. That session is the creature's long-lived memory.
- Calls Hermes through `POST /v1/runs` and follows `GET /v1/runs/{id}/events`, not a blocking
  chat call. A delegation took 43 s in the spike, so the creature can say a short
  acknowledgement and report the result when the run ends. `/v1/runs/{id}/stop` backs cancel.
- Cuts the reply sentence by sentence into Piper, so speech starts before the reply ends.
- Owns the creature state machine and sends it to the board.
- Approvals still use the existing question and approval path unchanged.

### Hermes

- Service on `127.0.0.1` with its own state dir and API key (sops). The bridge is its only client.
- Toolset limited to delegation. The persona and the rules for when to speak aloud are in the
  repo, not in `~/.hermes`.
- Hermes allows one gateway per host. On galactica the API server is that host's gateway.

## Audio path and protocol

Uplink:
- `voice_start {utterance_id}` (JSON), then binary frames, then `voice_end`.
- 16 kHz mono PCM16 in frames of about 100 ms (about 32 KB/s). The existing I2S channel runs at
  22.05 kHz, so the receive side is reconfigured.
- Capped at 30 s per utterance. The buffer is in PSRAM, because internal RAM is the scarce resource.

Downlink:
- JSON: `creature {mood}`, `transcript`, `reply_text`, `speak_start`, `speak_end`.
- Speech is binary PCM16 at Piper's native 22.05 kHz, so playback needs no resampling.
- `cancel` from the board stops TTS and the Hermes run.

Every message gets a fixture in `packages/claude-board-proto` and a test on both sides, as with the
existing wire format.

## Creature states

| State | Trigger |
|---|---|
| idle | nothing happening |
| listening | the avatar is held, with a level ring from mic volume |
| thinking | transcribed, waiting on Hermes |
| speaking | Piper audio playing |
| attention | a session needs you, or a check-in is pending |
| offline | Hermes, whisper or Piper unreachable |

Session-driven moods (waiting, done, failed) are unchanged. An approval takes over the screen
even while the creature speaks.

The chat view is a short read-only scrollback of recent exchanges as round-screen bubbles.
Voice is the only input in v1. There is no on-screen keyboard.

## Proactive check-ins

Hermes cron jobs, and the bridge on session events, create check-ins. They show as the attention
state plus a text card. They are spoken only when urgent (a session waiting on you, a failed run)
and never in quiet hours (configurable, for example 22:00 to 07:00). Tapping the card replies by
voice. Non-urgent items wait silently.

## Failure modes

- Empty or garbled transcript: "didn't catch that", nothing is sent to Hermes.
- Hermes, whisper or Piper down: offline mood and a text card. Approvals and the session feed
  keep working, because the voice module fails independently inside the bridge.
- Run longer than 60 s: stop it and say so.

## Deployment and secrets

- Hermes: a pinned module or container on galactica, settled during implementation. Hermes' own
  docs call Nix support best-effort and say commits to `main` can break it, so it is pinned.
- whisper.cpp and Piper: native services on loopback, with models pinned in the nix store.
  Latency depends on galactica's CPU, so it is measured and a smaller whisper model is the fallback.
- The Hermes API key and the DeepSeek key live in galactica's sops file, never in the nix store.
- No per-app firewall rules. Everything new is loopback behind the bridge. The bridge keeps its one
  public token-gated endpoint.

## Security

- Audio and chat use the existing device token. That token now also lets a holder talk to Hermes,
  so the bridge adds per-token rate limits and the utterance cap.
- Delegate-only Hermes is the real boundary. Claude sessions it starts still go through board
  approvals. Tool output is never sent to the board.
- Text returned by a Claude session reaches Hermes and could carry prompt injection. Delegate-only
  plus approvals limits the effect. It does not remove the risk.
- Transcripts are logged as metadata only and not stored.

## Spike findings (2026-11-10, Hermes 0.23.0, scratch `HERMES_HOME` on raider)

Verified:
- `POST /v1/chat/completions` with a bearer key answers in about 2 s.
- `X-Hermes-Session-Id` keeps a conversation across separate requests.
- A brand-new session ID still knew a fact from another session, through Hermes' persistent memory.
- Asked in plain language, Hermes ran `claude -p` in a scratch project, fixed a bug, and reported the
  Claude `session_id` (43 s). A later request resumed that session by ID and relayed its answer (15 s).
- `--allowedTools Read,Edit` did **not** restrict the Claude session, which also used Bash and Skill.
  Tool limits therefore cannot rely on that flag. Approvals are the gate.
- Each turn carries about 12.6k prompt tokens of baseline context.

From documentation only, not tested:
- `/v1/runs`, its events stream, `/stop` and `/steer`.
- Hermes' own voice mode, local STT and Piper TTS.
- NixOS module and container options.
- A single gateway per host.

## Unverified assumptions to check first

1. **Mic path.** Waveshare lists a dual-microphone array behind an **ES7210 audio ADC** on the 1.75C,
   with the ES8311 on the playback side. So capture probably goes through the ES7210, not the ES8311
   the firmware drives today. Its pins, I2C address (commonly 0x40, unverified) and whether the
   mics are analog are not on Waveshare's wiki pages. They are in the schematic and the example repo
   (`waveshareteam/ESP32-S3-Touch-AMOLED-1.75C`), which the first plan task reads. The existing I2S
   receive channel on GPIO10 may or may not be the mic's data line. No official 16 kHz record example exists.
2. **Hermes delegate-only.** Hermes has a `delegation` toolset containing only `delegate_task`, but
   its children inherit the parent's toolsets and keep `execute_code`, and the docs give no way to
   give the API server its own toolset list (the config keys conflict). Delegate-only is therefore
   **not guaranteed by configuration**. The plan treats it as a risk to retire first. The fallback,
   which also fits better, is a small MCP server in the bridge exposing exactly "start, steer, read
   session" tools, with Hermes' terminal and file toolsets disabled. This also keeps the authority
   boundary in our code and not in Hermes' config.
3. whisper.cpp (1.9.5) and Piper (1.8.0) exist in nixpkgs. Their latency on galactica (i5-1340P,
   12 cores, no GPU) is still to be measured, release to first spoken word.

### Gate results (2026-11-10)

Full workings are in the implementation plan's gate reports; the decisions that matter:

- **Mic (G1, read-only, not yet flashed):** ES7210 on the shared I2C bus (SDA 15, SCL 14), 7-bit
  address 0x40; it shares BCLK 9, WS 45 and MCLK 42 with the ES8311; data-in is GPIO 10, which is the
  existing I2S RX channel's DSIN. Two analog mics (MIC1+MIC2, downmixed in software), gain 24 dB set
  after open. TX and RX share one clock on the port, so capture at 16 kHz and playback at 22 050 Hz
  must be strictly sequential. Waveshare's schematic and Arduino sample put MCLK on GPIO 16; this
  firmware and the BSP use 42, and the schematic looks like an older revision. Still to verify on the
  flashed board: that samples are live, and the gain.
- **Hermes tool-less (G2):** proven with `platform_toolsets: {api_server: [], cron: []}` in the
  Hermes `config.yaml`, plus `API_SERVER_ENABLED=true`, `API_SERVER_KEY`, `API_SERVER_PORT` and
  `API_SERVER_HOST=127.0.0.1` in its `.env`. **Both lists matter:** with only `api_server: []`, a job
  created through the API's cron endpoint still ran a real terminal command. `GET /v1/toolsets` then
  lists every toolset disabled, and the model reports it has no shell and no file tool. Run
  continuity uses a `session_id` field in the `/v1/runs` JSON body; `X-Hermes-Session-Id` is ignored
  there (it only works on `/v1/chat/completions`). `SOUL.md` in `HERMES_HOME` carries the persona
  and is read live. Deploy with Hermes' NixOS module (`settings`, `environmentFiles`,
  `hermesHomeFiles`), not the container, whose mode is built for agent self-modification.
- **Speech latency (G3, galactica, 8 threads, synthetic speech only):** whisper.cpp `ggml-base.en`
  transcribes 5 s in 0.6 s (`small.en` took 1.8 to 2.2 s, so `base.en` is chosen). Piper
  `en_US-lessac-medium` (22 050 Hz mono PCM16) speaks the first sentence in 0.13 s through a resident
  HTTP server (1.2 to 1.6 s cold through the CLI). nixpkgs `piper-tts` has no HTTP entry point (a small
  wrapper is needed) and nixpkgs has no model packages (`fetchurl` with hashes). Real human speech
  and long-text Piper requests are untested.
4. Claude sessions started by Hermes inherit `~/.claude/settings.json` hooks, so they should appear
   on the board. This is untested.

## Delivery in three steps

1. **Voice path.** Mic, uplink, whisper, Hermes with a fixed persona and no tools, Piper, playback,
   cancel, creature states, offline handling.
2. **Delegation.** Hermes starts, steers and reports on Claude Code sessions, and approvals stay the gate.
3. **Check-ins.** Hermes cron and bridge events, urgency rules and quiet hours.

Each step ends with a working board.

## Testing

- Proto fixtures for every new message, pinned from both sides.
- Bridge integration tests with fake whisper, Piper and Hermes servers: the happy path, cancel and
  each failure mode above.
- Host UI tests and `just board preview` renders for the new states.
- On device: a measured audio round-trip latency and a heap check with the mic buffer allocated.

## Out of scope

Wake word, an on-screen keyboard, multiple creatures or users, and running Hermes on any other host.
