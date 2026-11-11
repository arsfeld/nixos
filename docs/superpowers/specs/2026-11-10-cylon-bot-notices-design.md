# Cylon Bot notices: a board that is not only for Claude Code

Date: 2026-11-10. Status: design, awaiting review.

## Goal

The Cylon Bot becomes a home companion whose face is the creature. Claude Code is one integration
among several, not the reason the board exists. Today every layer below the creature is shaped by
Claude Code hooks: the wire types follow hook events, the bridge's endpoints are the hooks' endpoints,
and tapping the avatar opens the Claude session list.

This spec is sub-project 1 of 4. It adds a generic **notice**: something any producer can tell you
about through the creature, with optional tap actions whose outcome goes back to the producer. It
also separates the bridge into a Claude-free core and a Claude adapter.

## The four sub-projects

| # | Sub-project | Depends on |
|---|---|---|
| 1 | **Platform: notices** (this spec). Bridge, proto, the board's notice card, one HA producer as proof | — |
| 2 | **Board: creature-first UX.** A SESSIONS command arc, the avatar tap no longer opening the Claude session list, urgent-takeover polish | 1 |
| 3 | **Producers.** Calendar lookahead, an ntfy relay, more HA automations. Mostly configuration | 1 |
| 4 | **Creature step 2 revised.** Delegation (`docs/superpowers/plans/2026-11-10-cylon-bot-creature-delegation.md`) rebuilt on notices: completion reports become notices | 1 |

Step 2 waits for this spec's implementation.

## Decisions

| Question | Decision |
|---|---|
| Near-term non-Claude sources | Home and life: Home Assistant events, calendar, ntfy. Fleet ops and other agents are out of scope |
| How an event reaches you | **Through the creature**: a spoken line plus a card that stays until tapped, like today's reminders. No persistent ring presence |
| How events reach the bridge | **One generic, token-gated push endpoint**, `POST /v1/notify`. The bridge knows nothing about HA events |
| Actions | A notice may carry up to 4 labelled actions. The outcome is POSTed to a **callback URL** that must match an allowlisted prefix |
| Claude Code's place | An **adapter** inside the bridge (approach A). Hooks on the nine hosts do not change |
| Claude's questions | **Stay a separate concept** (`Ask`), not folded into notices. See "Concepts" |
| Sessions on the board | The rim keeps showing them as ambient activity; the list moves behind a command arc in sub-project 2 |
| `reminder` | **Retired.** A due timer becomes a notice with `source: "timer"` |

Approaches considered for the bridge: (A) a generic core with a Claude adapter inside the bridge,
chosen; (B) the hooks speak the generic API and the bridge knows nothing of Claude, rejected for now
because it changes every host's hook at once and moves the approval-fit logic (the 160-byte rule,
scrubbing) away from the code tested against the board; (C) bolt `/v1/notify` on beside unchanged
Claude code, rejected because it leaves the bridge's core Claude-shaped. A leaves B open.

## Concepts

| Concept | What it is | Produced by |
|---|---|---|
| **Notice** (new) | Something you are told once: `{id, source, title, text, urgency, actions[], expires}`. Resolves to one tap or to nothing | `/v1/notify`, timers |
| **Ask** (today's `question`) | A held, multi-question, multi-select request whose answer returns to a blocked caller, with an "on computer" decline and a 60 s hold | the Claude adapter |
| **Activity** (today's sessions and feed) | Long-lived things with a state, shown on the rim | the Claude adapter |

Asks and notices stay separate because their needs barely overlap: asks need multi-question,
multi-select, decline and a held reply; notices need speech, quiet hours, callbacks and expiry. They
share the board's wheel and a `source` label. What stops being Claude-specific is the bridge's core:
notices, timers, voice and MCP know nothing about Claude.

## Wire protocol (version 6, additive)

Bridge to board:

```json
{"t":"notice","id":"9f2c…","source":"laundry","title":"Washer done","text":"Load finished 2 min ago","urgency":"normal","actions":["Snooze 10 min"]}
{"t":"notice_clear","id":"9f2c…"}
```

`question` gains an optional `source` (absent means `"claude"`). `id` is 128 random bits in hex, like
`AskId`. An unknown `urgency` parses as `normal`.

Board to bridge:

```json
{"t":"notice_reply","id":"9f2c…","action":"Snooze 10 min"}
{"t":"notice_reply","id":"9f2c…","action":null}
```

`action: null` is a plain dismiss. An `action` that is not one of the notice's labels is ignored by
the bridge and logged.

`reminder` is no longer sent. An old board against the new bridge ignores `notice`, so between the
galactica deploy and the flash a due timer is still spoken (speech is bridge-side) but shows no card.

### Urgency

| `urgency` | Spoken | Board |
|---|---|---|
| `low` | never | card |
| `normal` | yes, except in quiet hours | card |
| `urgent` | always, quiet hours included | takes over the screen like a question |

## Bridge

### Structure

- **Core**, with no Claude knowledge: `board.rs` (the socket), `voice/`, `timers.rs`, `mcp/`, and the
  new `notices.rs` (the store, expiry, quiet hours, routing an outcome to its sink).
- **`notify.rs`**: the HTTP front of the store (`POST /v1/notify`, `DELETE /v1/notify/{key}`).
- **`claude/`**: today's `asks.rs`, `state.rs`, `feed.rs` and the hook routes from `http.rs`, moved
  unchanged. `AppState` holds them as `claude: ClaudeState`. Routes, payloads and behaviour do not
  change, so no host's hooks are redeployed.

### `POST /v1/notify`

Bearer token `cylon-bot-notify-token` (new, 256-bit, `galactica.yaml` only, `BRIDGE_NOTIFY_TOKEN_FILE`;
with it unset the endpoint answers 404). It is separate from the host token because every host holds
that one, and a leaked host token should not be able to speak in the house or put actions on the
board. Same constant-time compare and 500 ms failure delay as the other tokens. Served on the public
router, so producers off galactica can use it later.

```json
{ "source": "laundry", "key": "washer", "title": "Washer done",
  "text": "Load finished 2 min ago", "urgency": "normal",
  "actions": ["Snooze 10 min"],
  "callback": "http://127.0.0.1:8123/api/webhook/washer-xyz",
  "expires_in": 3600 }
```

| Field | Rule |
|---|---|
| `source` | required, 1–24 bytes, `[a-z0-9_-]` |
| `key` | optional, 1–64 bytes, `[A-Za-z0-9_.-]`. A live notice with the same `source` and `key` is replaced (its callback gets `replaced`) |
| `title` | required, 1–60 bytes |
| `text` | optional, up to 240 bytes |
| `urgency` | optional, default `normal` |
| `actions` | optional, at most 4 distinct labels of 1–24 bytes |
| `callback` | optional; must start with one of `BRIDGE_NOTIFY_CALLBACK_PREFIXES` (comma-separated). Required when `actions` is non-empty |
| `expires_in` | optional seconds, default 3600, 10–86400 |

Anything outside these rules is a 400 naming the field, never silently cut. Body limit 8 KiB.
Success is `202 {"id": "…"}`, returned at once.

`DELETE /v1/notify/{source}/{key}` retracts a live notice (for example, the doorbell was answered at
the door): `notice_clear` goes to every board and the callback gets `retracted`. 404 when no such
notice is live.

At most 20 live notices; a 21st drops the oldest, whose callback gets `expired`.

### Outcomes and callbacks

Each notice ends exactly once, with a `reason`: `chosen`, `dismissed`, `expired`, `replaced` or
`retracted`. When it has a callback, the bridge POSTs:

```json
{"id":"9f2c…","source":"laundry","key":"washer","action":"Snooze 10 min","reason":"chosen"}
```

One attempt, 5 s timeout, never retried. A failure logs `notify: callback error=<timeout|refused|status>
source=<s>` and changes nothing on the board. The prefix allowlist exists so the notify token cannot
make galactica POST anywhere. HA's webhook triggers are local-only by default, and the bridge is on
the same host, so `http://127.0.0.1:8123/api/webhook/` is the expected entry.

The first reply from any board wins: the notice resolves, `notice_clear` goes to every board, and a
later reply for that id is ignored.

### Speech and quiet hours

A spoken notice says `"<title>. <text>"` (or just the title) through the existing line queue, which
already waits while the creature is busy and until earlier audio has played, and uses a bridge-owned
utterance id (`REMINDER_ID_BASE`, renamed `LINE_ID_BASE`). `BRIDGE_QUIET_HOURS`, e.g. `22:00-07:30`,
in America/Toronto, may cross midnight; unset means no quiet hours. The decision to speak is made when
the notice is accepted, not when the line reaches the front of the queue. With voice off, nothing is
spoken and the card still shows.

Today's rule for which socket may claim a timer (it heard its board within two pings plus 10 s)
applies to speaking any notice. The card goes to every board.

### Timers

`Timers` stays as it is, persisted in `timers.json`. When one is due, the bridge creates a notice
`{source: "timer", title: "Reminder", text: <label>, urgency: "normal"}` with no callback, in place of
today's `reminder` message. The spoken line stays `"Reminder. <label>."`. Today's 60-minute late
delivery with no board connected is unchanged.

### Lifetime

Notices live in memory: a bridge restart loses them, as it loses sessions. A board that connects
receives every live notice after `state`. With no board connected, a notice waits until it expires and
its callback then gets `expired`. A sweep (the existing 60 s one) expires notices.

### Logs

Source, key, urgency, reason and lengths. Never title, text or action labels.

## Board

### Proto `Model`

- Holds live notices in arrival order; applies `notice` (deduplicated by id) and `notice_clear`.
- A `state` snapshot does not drop notices: they have their own lifetime and the bridge re-sends the
  live ones on connect.
- `reply(id, action) -> ClientMsg::NoticeReply` and removes the notice locally.
- `current_notice()` is the oldest live notice; questions take priority over it.

### Firmware

- Today's reminder card becomes the notice card: `source` as a small label, then title and text. The
  reminder-specific heading (`reminder_heading` in the controller) goes.
- No actions: a tap dismisses (`action: null`), as a reminder tap does today, and stops a bridge-owned
  line being spoken, through the existing cancel path.
- With actions: the options appear on the question wheel with a final "Dismiss" row.
- Questions beat notices. A notice behind a question appears once the question is gone.
- Several notices queue oldest first, with a "+N" badge.
- `urgent` uses the existing question takeover. Polishing it is sub-project 2.
- The tap guard (taps ignored for 500 ms after a different item takes the screen) applies to notices.

## First producer: the washer

One HA automation proves the path end to end. On the washer finishing, `rest_command.cylon_bot_notify`
posts a notice with `key: "washer"` and the action "Snooze 10 min", with a callback to an HA webhook
trigger that waits 10 minutes and notifies again.

The token reaches HA through sops-nix: a `sops.templates` entry renders `/var/lib/hass/secrets.yaml`
with `cylon_bot_notify_auth: "Bearer <token>"`, owned by `hass`, and the `rest_command` header reads
`!secret cylon_bot_notify_auth`. No `secrets.yaml` exists there today; the plan checks that nothing
else writes one. Which entity marks the washer finishing is settled while writing the plan, from HA's
state.

## Locks and other sensitive actions

The creature can still never touch a lock: a notice action is a tap by a person, and HA's automation
is what acts on it. But a leaked device token could then answer such a notice. So no producer in this
work offers lock, alarm or camera actions, and adding one later is a decision for that automation,
made knowingly.

## Deploy order

galactica (the bridge and HA) first, then flash the board. No host's hooks change.

## Testing

- **Wire fixtures**: `notice.json`, `notice_clear.json`, `notice_reply.json` (client to bridge, so
  listed in `CLIENT_FIXTURES`), and `question.json` with and without `source`. Pinned by the bridge's
  `tests/wire.rs` and parsed by the proto tests, as now.
- **Bridge unit tests**: every validation rule, key replacement, retraction, the 20-notice cap,
  expiry sending `expired`, the callback prefix allowlist, exactly one outcome per notice, first reply
  wins, quiet hours (the `normal`/`urgent` split, a window across midnight, unset), timers arriving as
  notices.
- **Bridge HTTP test** with a local callback server: notify, reply over a board socket, callback body.
- **Proto `Model` tests**: ordering, deduplication, `state` not dropping notices, question priority.
- **UI host tests**: the card with no actions and with four, the "+N" badge, the tap guard.
  `just board preview` renders the screens.
- The existing Claude tests pass unchanged after the move into `claude/`.
