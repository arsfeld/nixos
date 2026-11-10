# Claude Board: session feed and remote approvals

Date: 2026-11-09. Builds on `2026-11-09-claude-board-design.md` (phase 1) and
`2026-11-09-claude-board-hook-findings.md`.

## Goal

From the board, see what each Claude Code session is doing now and did recently: the prompts,
Claude's replies and the tool calls (the command or file path). Approve or deny tool calls from
the board without going to the terminal.

## Scope

In: richer hooks, a per-session history buffer on the bridge, a protocol extension, a feed view in
the board firmware, and a `PermissionRequest` hook for every tool.

Out: sending prompts or interrupts into a session, voice, starting sessions. Sending input is a
separate design. Claude Code Channels (a local MCP server pushing messages into an interactive
session, launched with `--dangerously-load-development-channels`) is the likely mechanism.

## Decisions and why

- **Hooks, not Remote Control or Channels, supply the feed.** Remote Control has no documented
  third-party API: it is a claude.ai and mobile front end that routes through Anthropic's servers.
  A Channel never sees the transcript; only what Claude passes to its `reply` tool reaches it, and
  custom channels need a development flag and an interactive session on every launch. Hooks cover
  every session on every host without flags.
- **History lives in the bridge, in memory, bounded.** About 200 entries per session. No transcript
  content at rest. A bridge restart empties the feeds; each session's feed restarts on its next
  event. This matches the existing registry.
- **Entries are prompts, replies and tool calls.** Tool output is not sent, only an ok or failed
  marker. Output can be large (build logs) and is the likeliest place for secrets.
- **The board watches one session at a time.** It has roughly 118 KB of free internal RAM, so it
  cannot buffer every session. The bridge holds the history; the board asks for one session.

## Hooks

`claude-board-hook` gains events, all forwarded to a new endpoint `POST /v1/feed`:

| Hook | Entry kind | Text |
|---|---|---|
| `UserPromptSubmit` | `prompt` | `.prompt`, 2 KB |
| `PreToolUse` | `tool` | tool name plus a one-line summary (Bash command, file path, Grep pattern), 300 chars |
| `PostToolUse` | `result` | `ok` |
| `PostToolUseFailure` | `result` | `failed` |
| `Stop` | `reply` | `.last_assistant_message`, 4 KB |

- Truncation happens on the host in `jq`, so large content never leaves the machine.
- A short regex pass scrubs `Authorization:`, `Bearer …`, `*_TOKEN=…` and `password=…` from tool
  summaries. This is best-effort and is not a guarantee of redaction.
- `/v1/feed` never touches the registry and never cancels held questions. `/v1/event` keeps its
  current meaning. `Stop` still posts to `/v1/event` and additionally posts a `reply` to `/v1/feed`.
- Failure rules are unchanged: silent, exit 0, and a one-minute pause marker after a connection
  failure.
- `claude-board-install-hooks` registers the new hooks.

## Bridge

- New `feed.rs`: `HashMap<(host, session), VecDeque<Entry>>`, 200 entries per session. An entry has
  a per-session sequence number `n`, `ts`, `kind` and `text`.
- Entries are dropped on `SessionEnd` and on expiry, the same as the registry.
- `POST /v1/feed` (host token) appends and broadcasts to board sockets watching that session.
- Watch state is per socket and disappears with it.

## Protocol

`claude-board-proto` and `tests/fixtures/board/*.json` change together; `tests/wire.rs` and the
firmware host tests both read the fixtures.

- Board to bridge: `watch {host, session}`, `unwatch`.
- Bridge to board: `history {host, session, entries[]}` (newest 50), then `entry {host, session, n,
  ts, kind, text}` while watching. An unknown session gets an empty `history`, and the board shows
  "ended".
- `PROTOCOL_VERSION` bumps. Older firmware ignores unknown messages, as today.
- A lagging socket gets a fresh `history`, not a gap.

## Board UI

The detail page exists already (`ui/ui/detail.slint`, `Nav::Detail` in `ui/src/controller.rs`). It
has placeholder `summary` and `recent` properties for this work.

- `open_detail_at` sends `watch`; going back, or losing the socket, sends `unwatch` and clears the
  buffer.
- The header stays (host, project, state pill). The `Flickable` becomes the feed, newest at the
  bottom, following unless the user has scrolled up.
- Entries carry a kind glyph. Prompt: wrapped, 3 lines. Tool: monospace, one line, elided. Reply:
  wrapped, 5 lines. A failed result puts a red marker on its tool line. Tapping an entry shows its
  full truncated text in an overlay.
- The board keeps at most 50 entries and trims the oldest. The buffer is allocated in PSRAM.
- Glyph limits are unchanged: non-Latin text renders as missing-glyph boxes.

## Approvals for all tools

- The `PermissionRequest` hook gets a catch-all matcher (today only the question tool). It sends
  `{tool_name, tool_input}` to `/v1/ask`; the bridge builds a question-style message with
  `tool_name` and a summary (command, or path plus an edit snippet).
- The board shows the existing question screen with **Allow**, **Deny** and **Use computer**. Use
  computer declines and falls through to the terminal prompt, as today.
- Decisions: Allow returns `{"behavior":"allow"}`; Deny returns `{"behavior":"deny","message":
  "Denied from the board"}`. The question tool keeps `updatedInput.answers`.
- Held asks are cancelled only by events that mean Claude moved on (`Stop`, `UserPromptSubmit`,
  `SessionEnd`, `StopFailure`), never by `/v1/feed`. A stale ask times out at the hook's 80 s limit.
- Parallel tool calls: a `PostToolUse` for call B must not clear an ask for call A. Whether
  `PermissionRequest` carries a `tool_use_id` to match on is unmeasured and is the first task of the
  plan.
- In auto mode no permission dialog opens, so no approvals arrive; only the feed works there.

## Security

Feed content (prompts, commands, replies) is more sensitive than the session state the bridge held
before. The bridge stays public and token-gated; `/v1/feed` uses the host token. Tool output is
never sent. Approving a tool call is authority over a session, as with questions today.

## Failure behaviour

- A failed hook drops that entry silently.
- A bridge restart empties the feeds until new events arrive.
- A board with no bridge support (`PROTOCOL_VERSION` too low) shows the old detail page.

## Testing

- Bridge: unit tests for the ring buffer, watch and broadcast, cancel semantics, and per-session
  cap; `tests/wire.rs` pins the new messages to fixtures.
- Firmware: host tests parse the same fixtures; a Slint render test covers the feed page.
- Hook: `packages/claude-board-hook/test` gains a case per new event, truncation and scrubbing.
- Measurement: capture real payloads for the new hooks on the installed Claude Code version and add
  them to the hook-findings doc, including whether `PermissionRequest` has `tool_use_id`.
