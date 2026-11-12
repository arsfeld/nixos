# Cylon Bot power saving: findings

Spec: `2026-11-11-cylon-bot-power-design.md`; plan: `../plans/2026-11-11-cylon-bot-power.md`.

**Nothing below has been measured yet.** The code landed on 2026-11-11 with the board not attached to raider; every
row is a step for whoever next has the board on the desk (`nix develop -c just board monitor`).

## Battery drain (1 h idle, unplugged, `battery:` log lines)

Flash the commit named in each row, unplug, idle one hour, record the first and last `battery:` lines.

| Build | Commit | Start mV / % | End mV / % | USB mA (meter, if any) |
|---|---|---|---|---|
| Baseline (before changes) | `44db2fd2` | not measured | not measured | not measured |
| After PM and loop pacing | `dc142d8` | not measured | not measured | not measured |
| After dark panel | `a33b4dd` | not measured | not measured | not measured |
| Light sleep on (`LIGHT_SLEEP = true`) | — | not measured | not measured | not measured |

## Board gate

| # | Check | Result |
|---|---|---|
| 1 | Idle 2.5 min: `power: Dark`, panel off; a touch lights it and does not open the list | not run |
| 2 | A question while Dark lights the panel and chimes | not run |
| 3 | A reminder while Dark lights it and is spoken | not run |
| 4 | Unplugged, idle 12.5 min: `sleep: deep`; a touch wakes it (`wake: touch`), else BOOT (`wake: boot`) | not run |
| 5 | On USB, idle 15 min: no `sleep: deep` | not run |
| 6 | After a deep-sleep wake it connects without `waiting for the clock` | not run |
| 7 | Voice hold and reply work after waking from Dark, and with PM on | not run |
| 8 | Eye sweep still smooth by eye with PM and the paced loop | not run |

## Light sleep gate (`LIGHT_SLEEP` in `app/src/sleep.rs`, off until this passes)

| Check | Result |
|---|---|
| Websocket stays connected through one hour Dark (no reconnect lines) | not run |
| A question sent while Dark lights the panel within 1 s | not run |
| A voice hold and reply afterwards work | not run |

If check 4 finds that GPIO 11 does not wake the chip, deep sleep wakes on BOOT only; if neither does, turn deep
sleep off in `sleep::deep_sleep`'s caller and record which failed here.
