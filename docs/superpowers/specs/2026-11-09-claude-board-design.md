# Claude Board: an ESP32 control surface for Claude Code sessions

## Goal

A Waveshare ESP32-S3-Touch-AMOLED-1.75C (466×466 round AMOLED, touch, mic,
speaker, 8 MB PSRAM, 32 MB flash) that shows the state of every Claude Code
session across the fleet and lets the user answer Claude's multiple-choice
questions with a tap. A later phase starts new sessions by voice in chosen
project directories.

The board exists because the on-screen keyboard that ships with its demo firmware
is too small to type a Wi-Fi password, and because glancing at a physical
object is cheaper than opening a computer.

## Priorities (from the user)

1. **Check the status of sessions** (all hosts, one glance).
2. **Answer Claude's questions** from the board.
3. **Start new sessions by voice** in specific project directories, as the
   Claude desktop and iOS apps do. Spawned sessions run in auto mode, so no
   confirm step is needed; the project and prompt are shown as it starts.
4. Permission approvals are optional and last. Sessions run in auto mode, so
   they rarely arise.

## Scope and phasing

One design, two phases. The bridge API carries phase-2 messages from day one so
phase 2 needs no rework.

- **Phase 1:** hooks on every host, the bridge, the board firmware with the
  session list and tap-to-answer questions.
- **Phase 2:** per-host runners, a project list, voice capture and
  speech-to-text, spawning sessions; free-text answers by voice.
- **Later / optional:** permission approvals for non-auto sessions.

Out of scope: talking to claude.ai's Remote Control channel directly (see
Rejected approaches), cloud/web sessions, Wi-Fi provisioning UI on the board.

## Rejected approaches

- **Impersonating the Remote Control client.** Remote Control is outbound-only
  from the local `claude` process to the Anthropic API, requires a claude.ai
  login, and has no documented wire protocol
  (https://code.claude.com/docs/en/remote-control). Building on an
  undocumented, OAuth-gated protocol is fragile.
- **Keeping the Brookesia demo firmware** with an added app. Large build,
  coupling to Waveshare's tree, for one small app. The factory image
  (`firmware/ESP32-S3-Touch-AMOLED-1.75-FactoryOnly-260805.bin`, offset `0x0`
  in https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75) restores the
  demo at any time.
- **Arduino or ESPHome.** Weaker fit for a custom round UI with live updates.
- **Injecting Wi-Fi credentials into the demo's NVS.** Tried on 2026-11-09:
  the key names match, but the board never connected, and the Wi-Fi library's
  stored-config layout is closed. Reverted; original NVS restored.

## Architecture

```
 each host (raider, galactica, basestar, ...)     bridge (galactica)             board
 +------------------------------------------+   +----------------------+   +------------------+
 | Claude Code, global hooks (home-manager): |   | claude-bridge        |   | ESP-IDF + LVGL    |
 |  SessionStart/UserPromptSubmit/           |-->| - session registry   |-->| - session list    |
 |  Notification/Stop/SessionEnd  -> event   |   | - pending questions  |WS | - question card   |
 |  PermissionRequest(AskUserQuestion) -> ask|<--| - holds ask requests |<--| - tap -> answer   |
 +------------------------------------------+   +----------------------+   +------------------+
```

- **Hooks** are the only thing installed on each host. They POST a small JSON
  event to the bridge. They are installed once through home-manager so every
  host in the flake gets them.
- **The bridge** is a small native service on galactica, declared with
  `media.services.<name>` (gateway entry, no container). It keeps the live
  session list in memory and relays events to the board over one WebSocket.
- **The board** is a thin WebSocket client. It holds only a device token and
  its Wi-Fi credentials.
- **Fallback:** if the board is offline or does not answer within the timeout,
  the `ask` hook returns no decision and Claude Code shows its normal terminal
  prompt. The board never makes things worse than today.

### Hook events and derived state

| Hook event | Effect on the session card |
|---|---|
| `SessionStart` | created, state `idle` |
| `UserPromptSubmit` | `working` |
| `Notification` | `waiting` (for the matching notification types) |
| `Stop` | `idle` (or `done` when the work is finished) |
| `SessionEnd` | removed |
| `PermissionRequest` matched on `AskUserQuestion` | `waiting`, plus a pending question |

A session with no event for several hours expires. State `error` is set when a
hook reports a failure; the exact event is settled in the phase-1 spike below.

### Answering questions

Claude's question tool is answered from a `PermissionRequest` hook that returns
`allow` with `updatedInput` containing the original `questions` array and an
`answers` map keyed by exact question text. A bare `allow` leaves the question
open. Documentation:
https://code.claude.com/docs/en/agent-sdk/user-input and
https://code.claude.com/docs/en/hooks. Behaviours the implementation must
handle:

- Answers are keyed by exact question text; a mismatch is reported to Claude as
  "not answered" while the screen shows it answered.
- Multi-select answers are joined with commas.
- If the user answers in the terminal first, the first decision wins; the
  bridge clears the board card when the next event for that session arrives.
- "Other" (free text) in phase 1 shows "answer on computer" and returns no
  decision, so the terminal prompt stays. Phase 2 answers it by voice.

### Protocol

- **Hooks to bridge:** `POST /v1/event` with `{host, session, cwd, event, ts}`,
  authenticated by a per-host token. `POST /v1/ask` carries the tool input and
  is held open until answered or timed out.
- **Bridge to board and back:** one WebSocket authenticated by a device token.
  The bridge sends a full `state` snapshot on connect and diffs afterwards,
  plus `question {id, session, questions[]}`. The board sends
  `answer {id, answers}`. Question ids are unique and single-use, so a late or
  replayed answer is ignored.
- **Phase-2 messages, reserved now:** `spawn {host, project, prompt}` from the
  bridge to a per-host runner, and an audio upload from the board.

### Reachability and secrets

- The bridge is reachable on the LAN and the tailnet only; there is no public
  route and it is not behind Cloudflare. The board connects over the LAN.
- All tokens (per-host, device) come from sops.
- Approval and spawn are remote code execution authority. The bridge enforces
  single-use question ids, authenticated clients, and a short timeout. Whether a
  tool allowlist is needed for approvals is decided when approvals are built.

## Board firmware

- **Stack:** ESP-IDF (v5.5.x, per Waveshare's Brookesia README), LVGL,
  Waveshare's `esp32_s3_touch_amoled_1_75` board support package for display,
  touch and power. Built reproducibly with nix.
- **Wi-Fi:** SSID and password compiled in from a sops secret at build time.
  Changing network means reflashing. No on-device provisioning in phase 1.
- **Screens:**
  - *Idle:* near-black and dimmed (AMOLED burn-in), showing only the count of
    waiting sessions and a faint ring. A chime plays when something needs the
    user.
  - *Sessions:* vertical swipe list, waiting sessions first. Each card has the
    project name, host chip, state colour (working blue, waiting amber, idle
    grey, done green, error red) and time in state.
  - *Question:* question text truncated to fit, up to four large option
    buttons, one question at a time for multi-question prompts.
  - *Detail:* last assistant message summary and time in state.
- **Recovery:** the factory image restores the stock demo. A full-flash backup is
  taken before the first flash of custom firmware.

## Phase 1 spike (first implementation step)

Before building anything, confirm on the user's installed Claude Code version
that a `PermissionRequest` hook on the question tool can answer it with
`updatedInput` in an interactive session, and which hook events carry the
states in the table above (in particular `error`, and which `Notification`
types mean waiting). Phase 1 depends on this; if it fails, the design is
revisited before further work.

## Phase 2 outline

- A runner on each host that can start Claude Code in a project directory with
  a prompt. Candidate mechanisms to compare in phase 2: `claude --bg`, the Agent
  SDK, `claude remote-control --spawn`. Whether spawned sessions also show up in
  the claude.ai and iOS session list is part of that comparison.
- A project list (host, path, display name) held in the bridge configuration.
- Voice: the board records and uploads audio, the bridge transcribes it
  (location to be decided: local model on galactica or an API), then the
  bridge sends `spawn` or the voice text as an answer.

## Error handling

- Board offline: asks time out and fall through to the terminal prompt; the
  bridge keeps the session list so the board catches up on reconnect.
- Bridge down: hooks fail fast and Claude Code behaves as if no hook were
  configured. Hooks must never block a session on bridge failure.
- Stale cards: expire by timeout; cleared by later events.
- Duplicate or late answers: ignored by id.

## Testing

- Bridge: unit tests for state derivation from event sequences and for the
  ask/answer flow (including timeout and replay); a NixOS VM test or
  equivalent for the service where practical.
- Hooks: a script that replays recorded events against a running bridge.
- Firmware: a simulated board client that speaks the WebSocket protocol, so the
  bridge is testable without hardware; manual checks of each screen on the
  device.
- The phase-1 spike gates the rest.
