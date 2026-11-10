# Claude Board: command arcs (volume, link, purge)

Date: 2026-11-10. Status: design approved in chat, awaiting spec review.
Mockups: https://claude.ai/artifact/QW7GQkZBWYxxF2Exe8euim (option B, bottom row for the three screens). They are
HTML approximations; the board's software renderer has no soft glows or gradient fills, and the real screens are
checked with `just board preview`.

## Goal

Three actions on the board's home screen, styled like the Centurion rather than like a settings menu, each two
touches or fewer from home:

1. **Volume**: change the speaker level, kept across reboots.
2. **Link**: show Wi-Fi and bridge status.
3. **Purge**: start a new Hermes session, so the creature forgets the conversation so far.

They are board-side controls for the person at the board, not voice commands. More actions may be added later;
the menu has three slots now.

### Decisions (from the brainstorm)

| Question | Decision |
|---|---|
| How the menu opens | A **swipe down that starts in the top 60 px** (the rim band) |
| Look | **B, rim commands**: the top third of the rim becomes three metal arc segments; the head stays put |
| Swipe up/down volume (uncommitted work in the tree) | **Kept as a shortcut** on home |
| Purge confirmation | **Hold for 1.5 s** while a red ring fills; letting go early cancels |
| What purge clears | **The conversation only**: a new Hermes `session_id`. Long-term memory and old sessions stay |
| Purge feedback | A **fixed spoken line**, "Memory purged. By your command.", through Piper only |

## Starting point

Swipe-to-change-volume landed in `2c1b5270` and this builds on it:

- `ui/src/touch.rs`: `set_vertical_swipes`, `Gesture::SwipeUp` / `SwipeDown`.
- `ui/src/audio.rs`: `VOLUME_DEFAULT` (80), `VOLUME_MIN` (10), `VOLUME_MAX` (100), `VOLUME_STEP` (10),
  `volume_step()`.
- `board_display.c`: `bd_set_volume()` (replacing `SPK_VOLUME`, applied on every speaker open and at once while a
  reply plays) and an unthrottled preview chime; `display::set_volume` wraps it.
- `app/src/main.rs`: the level is saved in NVS (namespace `board`, key `volume`) and read at boot.
- `ui/ui/home.slint`: `volume` / `volume-shown` and a grey volume pill shown after a swipe.

The bridge uses one fixed Hermes `session_id` (`BRIDGE_HERMES_SESSION`, default `creature`).

## Board

### Gestures on home

| Gesture | Menu closed | Menu open |
|---|---|---|
| Swipe down, starting at `y < 60` | open the menu | (nothing) |
| Swipe down, starting lower | quieter | (nothing) |
| Swipe up | louder | close the menu |
| Swipe right | (nothing, as today) | close the menu |
| Tap / hold the avatar | session list / talk, as today | the same; the menu closes |

`TouchTracker` gains `Gesture::EdgeDown`: a vertical swipe down whose touch-down was within `EDGE_BAND_PX` (60) of
the top. It is recognised only while vertical swipes are on, which the app turns on for home only. The menu also
closes after 10 s with no touch, and when a question takes over the screen.

### The menu

While the menu is open, the session arcs whose midpoint lies in the top third are hidden, and three command
segments take their place at radius ~200, each spanning 40° and centred at −44°, 0° and +44° from the top:

- **VOL** (left): speaker icon, current level.
- **LINK** (top): Wi-Fi icon.
- **PURGE** (right): reset icon, red edge. Drawn dimmed, and does nothing, while the bridge link is down.

Each segment is a static `Path` with its own tight box (`rim::arc_segment`), and the icons are pre-rendered sprites
or simple `Path`s, so opening the menu repaints only those boxes. Tapping a segment opens its page. `Page` gains
`volume`, `link` and `purge`; swipe right on any of them returns to home with the menu closed.

### Volume page

- 24 ticks around the rim over 240° (a gap at the bottom), lit up to the level, the last one brighter. The ticks
  are a model of tight-box `Path`s built once (`rim::ticks`); which are lit is worked out in Slint from the level.
- The level in large type, "AUDIO LEVEL" above it.
- − and + buttons step by `VOLUME_STEP` through the same code path as the swipe shortcut, so they share its NVS
  write and preview chime.
- The swipe shortcut on home keeps its pill, restyled as a short row of red ticks.

### Link page

A large signal icon of four arcs lit by RSSI (≥ −55, −67, −75, −85 dBm, else none), the RSSI in dBm, and rows:
NETWORK (SSID), ADDRESS (IPv4), BRIDGE (linked / down), VOICE (online / offline), UPTIME. All of it comes from the
board itself (`esp_wifi_sta_get_ap_info`, the station netif, the existing link and mood state, `esp_timer`), and is
refreshed every 2 s while the page is open. The bridge is not involved. SSIDs are rendered with the existing glyph
set; characters outside it draw blank.

### Purge page

The head small at the top, "PURGE MEMORY", one line of explanation, a HOLD button, and "RELEASE TO ABORT".

Holding the button for 1.5 s fills a red ring around the edge; letting go early resets it. The timing lives in
Slint: the button's `TouchArea.pressed` drives a timer-advanced progress, and completion fires a callback. No new
gesture code is needed: `TouchTracker`'s 450 ms hold is only a hold if the app accepts it, and the controller
accepts holds on the avatar only, so on this page the pointer stays pressed. The ring is 36 radial ticks round the
edge (`rim::ticks`, the same helper as the volume page's), each a static `Path` with its own tight box, lit from
the progress in Slint, so a step of the fill repaints only the tick that lights.

On completion the board sends `new_session` with a fresh utterance id, shows the `thinking` mood and returns to
home. The bridge's spoken line then plays through the normal speaking path. If no `session_reset` arrives within
10 s, the board drops back to `idle`.

## Protocol (`PROTOCOL_VERSION` 5)

| Direction | Message | Meaning |
|---|---|---|
| board → bridge | `{"t":"new_session","utterance":N}` | start a new Hermes session; `N` names the spoken confirmation |
| bridge → board | `{"t":"session_reset","utterance":N}` | done; sent whether or not voice is available |

After `session_reset`, when TTS is configured, the bridge sends `speak_start {utterance: N, sample_rate}`, binary
audio frames tagged `N`, `speak_end`, and the `idle` mood, exactly as for a spoken reply. Fixtures
`new_session.json` and `session_reset.json` go in `tests/fixtures/board/`, pinned by the bridge's `tests/wire.rs`
and parsed by the `claude-board-proto` tests. An older board ignores `session_reset`; an older bridge ignores
`new_session`.

## Bridge

- **Mutable session.** `HermesHttp` holds its session id behind a lock. `reset()` mints `<base>-<unix seconds>`
  (`creature-1794326900`), stores it, and writes it to `$STATE_DIRECTORY/hermes-session`. At startup the bridge reads
  that file if present and falls back to `BRIDGE_HERMES_SESSION`. Without the file, a bridge restart would bring
  the old conversation back.
- **NixOS.** `claude-board` gets `StateDirectory = "claude-board"`.
- **In-flight runs** finish on the session they started on; the reset applies from the next utterance.
- **Spoken line.** "Memory purged. By your command." goes straight to Piper and the Cylon effect, through the same
  path `timers.rs` uses for "Reminder. …". Hermes is not called.
- **Limits.** A reset counts toward the existing 10 utterances a minute per connection. Over the limit, the reset is
  refused and the bridge answers with the `idle` mood and no `session_reset`.
- **Logs.** `voice: utt=<id> session reset` and, on failure, the usual `stage=tts error=…` line. The session id is
  not logged.
- **Nothing is deleted.** Old sessions stay in Hermes' store and long-term memory is untouched.

## Failure cases

| Situation | Result |
|---|---|
| Bridge link down | PURGE dimmed, hold does nothing; volume and link work |
| Bridge without voice backends | Reset applies (it is only a string), `session_reset` sent, no speech |
| Piper fails | `session_reset` sent, no speech, `stage=tts` error logged |
| State file not writable | Reset applies in memory, warning logged, no crash; a restart reverts to the old id |
| Older bridge | `new_session` ignored; the board times out to `idle` after 10 s |

## Testing

- **Touch** (`ui/src/touch.rs`): `EdgeDown` versus `SwipeDown` by start position; edge swipes off when vertical
  swipes are off.
- **Controller**: menu open and close (each gesture, the 10 s timeout, a question taking over); the − and + buttons
  reach the same volume path as the swipes; purge completion sends `new_session` once; PURGE inert while unlinked.
- **Screens**: `just board preview` PNGs for home with the menu open and the volume, link and purge pages, plus
  headless tests that tap each segment at its real coordinates.
- **Proto and bridge**: the two fixtures from both sides; a reset changes `session_id` in the next `/v1/runs` body;
  a new bridge instance reads the id back from the state file; `session_reset` arrives with voice off.
- **On the board** (`just board monitor`): chime loudness at each level by ear, the level surviving a reboot, RSSI
  against what raider sees for the same network, and a purge followed by "what did I just ask you?".

## Deploy order

galactica (the bridge, with `StateDirectory`) first, then flash the board. Volume and link need no bridge change and
work against any bridge.

## Out of scope

Wiping Hermes' long-term memory, deleting old sessions, more than three commands, and controlling these actions by
voice.
