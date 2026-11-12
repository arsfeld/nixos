# Cylon Bot notices: a board that is not only for Claude Code

Date: 2026-11-10. Status: design, awaiting review.

## Goal

The Cylon Bot becomes a home companion whose face is the creature. Claude Code is one integration
among several, not the reason the board exists. Today every layer below the creature is shaped by
Claude Code hooks: the wire types follow hook events, the bridge's endpoints are the hooks' endpoints,
and tapping the avatar opens the Claude session list.

This spec covers the whole change, built and shipped as one:

1. **Notices**: a generic thing any producer can tell you about through the creature, with optional tap
   actions whose outcome goes back to the producer.
2. **A Claude-free bridge core**, with Claude Code moved into an adapter.
3. **A creature-first board**: the avatar is the creature's, the session list moves behind a command arc.
4. **A real producer**: a Google Calendar lookahead through Home Assistant.

Creature step 2 (delegation, `docs/superpowers/plans/2026-11-10-cylon-bot-creature-delegation.md`) is a
separate feature. It waits for this one and is revised afterwards to report through notices.

## Decisions

| Question | Decision |
|---|---|
| Non-Claude sources in this work | **A Google Calendar lookahead** through HA. Fleet ops, ntfy, other agents and other HA events are out of scope |
| How an event reaches you | **Through the creature**: a spoken line plus a card that stays until tapped, like today's reminders |
| How events reach the bridge | **One generic, token-gated push endpoint**, `POST /v1/notify`. The bridge knows nothing about HA or calendars |
| Actions | A notice may carry up to 4 labelled actions. The outcome is POSTed to a **callback URL** that must match an allowlisted prefix |
| Claude Code's place | An **adapter** inside the bridge (approach A). Hooks on the nine hosts do not change |
| Claude's questions | **Stay a separate concept** (`Ask`), not folded into notices. See "Concepts" |
| Sessions on the board | The rim keeps showing them as ambient activity; the list moves behind a **SESSIONS** command arc |
| Avatar tap | **Reopens the most recent card** (last reply or last notice). Hold stays push-to-talk |
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
{"t":"notice","id":"9f2c…","source":"calendar","title":"Dentist","text":"in 10 min · 123 Main St","urgency":"normal","actions":["Snooze 5 min"],"wake":true}
{"t":"notice_clear","id":"9f2c…"}
```

`question` gains an optional `source` (absent means `"claude"`). `id` is 128 random bits in hex, like
`AskId`. An unknown `urgency` parses as `normal`. `wake` is true when the notice will be spoken or is
`urgent`; the board lights a dimmed screen only then, so a low or quiet-hours notice lands without
lighting the room.

Board to bridge:

```json
{"t":"notice_reply","id":"9f2c…","action":"Snooze 5 min"}
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
| `urgent` | always, quiet hours included | takes over the screen like a question, `alert` mood, chime once |

## Bridge

### Structure

- **Core**, with no Claude knowledge: `board.rs` (the socket), `voice/`, `timers.rs`, `mcp/`, and the
  new `notices.rs` (the store, expiry, quiet hours, routing an outcome to its sink).
- **`notify.rs`**: the HTTP front of the store (`POST /v1/notify`, `DELETE /v1/notify/{source}/{key}`).
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
{ "source": "calendar", "key": "evt_abc123", "title": "Dentist",
  "text": "in 10 min · 123 Main St", "urgency": "normal",
  "actions": ["Snooze 5 min"],
  "callback": "http://127.0.0.1:8123/api/webhook/cylon-bot-calendar-…",
  "expires_in": 900 }
```

| Field | Rule |
|---|---|
| `source` | required, 1–24 bytes, `[a-z0-9_-]` |
| `key` | optional, 1–64 bytes, `[A-Za-z0-9_.@-]`. A live notice with the same `source` and `key` is replaced (its callback gets `replaced`) |
| `title` | required, 1–60 bytes |
| `text` | optional, up to 240 bytes |
| `urgency` | optional, default `normal` |
| `actions` | optional, at most 4 distinct labels of 1–24 bytes |
| `callback` | optional; must start with one of `BRIDGE_NOTIFY_CALLBACK_PREFIXES` (comma-separated). Required when `actions` is non-empty |
| `expires_in` | optional seconds, default 3600, 10–86400 |

Anything outside these rules is a 400 naming the field, never silently cut. Body limit 8 KiB.
Success is `202 {"id": "…"}`, returned at once.

`DELETE /v1/notify/{source}/{key}` retracts a live notice: `notice_clear` goes to every board and the
callback gets `retracted`. 404 when no such notice is live.

At most 20 live notices; a 21st drops the oldest, whose callback gets `expired`.

### Outcomes and callbacks

Each notice ends exactly once, with a `reason`: `chosen`, `dismissed`, `expired`, `replaced` or
`retracted`. When it has a callback, the bridge POSTs:

```json
{"id":"9f2c…","source":"calendar","key":"evt_abc123","action":"Snooze 5 min","reason":"chosen"}
```

One attempt, 5 s timeout, never retried. A failure logs `notify: callback error=<timeout|refused|status>
source=<s>` and changes nothing on the board. The prefix allowlist exists so the notify token cannot
make galactica POST anywhere. HA's webhook triggers are local-only by default and the bridge is on the
same host, so `http://127.0.0.1:8123/api/webhook/` is the configured prefix.

The first reply from any board wins: the notice resolves, `notice_clear` goes to every board, and a
later reply for that id is ignored.

### Speech and quiet hours

A spoken notice says `"<title>. <text>"` (or just the title) through the existing line queue, which
already waits while the creature is busy and until earlier audio has played, and uses a bridge-owned
utterance id (`REMINDER_ID_BASE`, renamed `LINE_ID_BASE`). `BRIDGE_QUIET_HOURS`, e.g. `22:00-07:30`,
in America/Toronto, may cross midnight; unset means no quiet hours. Whether a notice is spoken (and so
its `wake`) is decided when it is accepted, not when its line reaches the front of the queue. With
voice off, nothing is spoken, `wake` is true only for `urgent`, and the card still shows.

Today's rule for which socket may claim a timer (it heard its board within two pings plus 10 s)
applies to speaking any notice: exactly one socket speaks it. The card goes to every board.

### Timers

`Timers` stays as it is, persisted in `timers.json`. When one is due, the bridge creates a notice
`{source: "timer", title: "Reminder", text: <label>, urgency: "normal"}` with no callback, in place of
today's `reminder` message. The spoken line stays `"Reminder. <label>."`. Today's 60-minute late
delivery with no board connected is unchanged.

### Lifetime

Notices live in memory: a bridge restart loses them, as it loses sessions. A board that connects
receives every live notice after `state`. With no board connected, a notice waits until it expires and
its callback then gets `expired`. The existing 60 s sweep expires notices.

### Logs

Source, key, urgency, reason and lengths. Never title, text or action labels.

## Board

### Proto `Model`

- Holds live notices in arrival order; applies `notice` (deduplicated by id) and `notice_clear`.
- A `state` snapshot does not drop notices: they have their own lifetime and the bridge re-sends the
  live ones on connect.
- `reply(id, action) -> ClientMsg::NoticeReply` and removes the notice locally.
- `current_notice()` is the oldest live notice; questions take priority over it.

### The notice card

- Today's reminder card becomes the notice card: `source` as a small label, then title and text. The
  reminder-specific heading (`reminder_heading` in the controller) goes.
- No actions: a tap dismisses (`action: null`), as a reminder tap does today, and stops a bridge-owned
  line being spoken, through the existing cancel path.
- With actions: the options appear on the question wheel with a final "Dismiss" row.
- Questions beat notices. A notice behind a question appears once the question is gone.
- Several notices queue oldest first, with a "+N" badge.
- `urgent`: the card takes over the screen the way a question does (no swipe-back until handled), the
  creature shows `alert`, and the chime plays once. The command menu closes, as it does for a question.
- `wake: true` lights a dimmed screen; `wake: false` leaves it dim.
- The tap guard (taps ignored for 500 ms after a different item takes the screen) applies to notices.

### The avatar

- **Tap** reopens the most recent card: the creature's last reply or the last notice, whichever is
  newer, including one already dismissed. A notice already resolved reopens read-only, with no actions.
  With nothing to show, a tap does nothing. A tap while the creature speaks still stops it first, as
  today, and does not also open a card.
- **Hold** is push-to-talk, unchanged.
- Board-side only; the protocol does not change.

### The SESSIONS command arc

The menu gains a fourth arc. The four are VOL, LINK, SESSIONS, PURGE, left to right, each spanning 30°
with 4° gaps, centred at −51°, −17°, +17° and +51° from the top (today: three of 40° at −44°, 0°, +44°).
SESSIONS opens today's session list, unchanged, with a list icon. Each arc stays a static `Path` with
its own tight box. Tapping a rim arc still opens its session. Swipe right from the list returns home.

## Producer: Google Calendar lookahead

- HA gains the `google` integration (`extraComponents`). Signing in with OAuth is a one-time step in
  HA's UI; the calendar entity ids exist only after it, so they are filled into nix then.
- An automation declared in nix, `"automation cylon_bot"`, triggers on a calendar event start with
  offset `-0:10:00`, for each calendar listed, and posts through `rest_command.cylon_bot_notify`:

  | Field | Value |
  |---|---|
  | `source` | `calendar` |
  | `key` | the event's uid, cut to 64 bytes and reduced to the allowed characters |
  | `title` | the event summary, cut to 60 bytes |
  | `text` | `in 10 min`, then ` · <location>` when the event has one, cut to 240 bytes |
  | `urgency` | `normal` |
  | `expires_in` | 900 |
  | `actions` | `["Snooze 5 min"]` |
  | `callback` | `http://127.0.0.1:8123/api/webhook/<snooze webhook id>` |

- A second automation, triggered by that webhook (local only), acts only on `reason: "chosen"` with
  action `Snooze 5 min`: it waits 5 minutes and posts the same notice again with `text` `starting now`
  (location kept) and no actions, so a snooze happens at most once per event. The webhook id is a
  random value from sops, not in the store, because a webhook id is the only credential HA asks for.
- The token reaches HA through sops-nix: a `sops.templates` entry renders `/var/lib/hass/secrets.yaml`
  with `cylon_bot_notify_auth: "Bearer <token>"` and `cylon_bot_snooze_webhook: <id>`, owned by `hass`.
  The `rest_command` header reads `!secret cylon_bot_notify_auth`. No `secrets.yaml` exists there
  today; the plan checks that nothing else writes one before taking the path.
- All-day events are skipped (no 10-minute warning for a whole day).

## Locks and other sensitive actions

The creature can still never touch a lock: a notice action is a tap by a person, and an HA automation
is what acts on it. But a leaked device token could then answer such a notice. So no producer offers
lock, alarm or camera actions, and adding one later is a decision for that automation, made knowingly.

## Deploy order

galactica (the bridge and HA) first, then the HA OAuth step and the calendar ids, then flash the board.
No host's hooks change.

## Testing

- **Wire fixtures**: `notice.json`, `notice_clear.json`, `notice_reply.json` (client to bridge, so
  listed in `CLIENT_FIXTURES`), and a `question` fixture with `source`. `reminder.json` is deleted.
  Pinned by the bridge's `tests/wire.rs` and parsed by the proto tests, as now.
- **Bridge unit tests**: every validation rule, key replacement, retraction, the 20-notice cap,
  expiry sending `expired`, the callback prefix allowlist, exactly one outcome per notice, first reply
  wins, quiet hours (the `normal`/`urgent` split, a window across midnight, unset), `wake` in each case
  including voice off, timers arriving as notices.
- **Bridge HTTP test** with a local callback server: notify, reply over a board socket, callback body.
- **Proto `Model` tests**: ordering, deduplication, `state` not dropping notices, question priority.
- **UI host tests**: the card with no actions and with four, the "+N" badge, urgent takeover and no
  swipe-back, `wake` false leaving the screen dim, the tap guard, avatar tap reopening the last reply
  and a resolved notice read-only, the four-arc menu with SESSIONS opening the list. `just board
  preview` renders the screens.
- **Calendar**: an end-to-end check after deploy with a test event 12 minutes out, then a snooze.
- The existing Claude tests pass unchanged after the move into `claude/`.
