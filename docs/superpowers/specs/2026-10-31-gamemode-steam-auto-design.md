# Automatic GameMode for Steam games

## Problem

GameMode only activates for processes registered with `gamemoded`, which today
means games started through `gamemoderun`. Lutris does that by default; Steam
does it only for games whose launch options carry `gamemoderun %command%`. So
for most Steam games none of the gamemode effects fire — including the
`custom.start`/`custom.end` hooks that drive `gaming-boost` (background builds
yielding to the game), the CPU governor and the AMD/NVIDIA GPU performance
level.

Goal: every Steam game, native or Proton, in desktop mode or the gamescope
session, activates GameMode for exactly its lifetime, with no per-game setup.

## Rejected alternatives

- **`LD_PRELOAD=libgamemodeauto.so` on the Steam client.** The client process
  loads it too, so GameMode — and with it `gaming-boost` — would be on for as
  long as Steam is open, tray included.
- **Rewriting `LaunchOptions` in `localconfig.vdf`.** Steam rewrites that file
  while running, and it collides with hand-set options (MangoHud, `PROTON_*`).
- **A wrapping compatibility tool.** Covers Proton only and needs selecting per
  game or globally; native games are missed.

## Design

Steam starts every game under `reaper SteamLaunch AppId=<id> -- …`, and that
reaper lives exactly as long as the game. A user service registers each reaper
with gamemoded on the game's behalf.

### Component

`systemd.user.services.gamemode-steam-watch` in
`modules/constellation/gaming.nix`, beside the existing `programs.gamemode`
block, so it is on wherever `constellation.gaming` is (raider, blackbird).
`wantedBy`/`partOf` `graphical-session.target`, `Restart=on-failure`.

Its script is a `writeShellApplication` with `procps` and the systemd package
as runtime inputs. Every 2 seconds:

1. `pgrep -f '^reaper SteamLaunch AppId='` lists current reapers.
2. For each PID not in its in-memory seen-set, call
   `busctl --user call com.feralinteractive.GameMode /com/feralinteractive/GameMode com.feralinteractive.GameMode RegisterGameByPID ii $$ <pid>`.
   If the call fails (gamemoded unreachable), log it and leave the PID out of
   the set so the next pass retries. Any reply adds the PID to the seen-set: a
   reply other than `0` (already registered, rejected) would be the same next
   time, and retrying it logs an error in gamemoded every 2 seconds.
3. Drop PIDs from the seen-set that are no longer running.

The watcher never unregisters. gamemoded's own reaper thread checks every
registered PID each `reaper_freq` seconds (default 5) and unregisters dead
ones, which runs `custom.end`. Two games at once are two registrations, and
GameMode stays on until both are gone.

### Why D-Bus and not `gamemoded -r <pid>`

Verified in gamemode 1.8.2's source (`daemon/gamemoded.c`): `-r <pid>` is a
**toggle**. It ends GameMode for a PID that is already registered. A watcher
that restarted mid-game, losing its seen-set, would switch GameMode off for
the running game. `RegisterGameByPID` only ever adds: for a known PID it
returns `-1` and changes nothing (`game_mode_context_register` in
`daemon/gamemode-context.c`), so a restart costs one harmless error line in
gamemoded's journal.

The caller PID (`$$`, the watcher's shell) must be alive because gamemoded
resolves its executable for the supervisor allow/deny lists. Both are empty
in our config, so any supervisor is accepted.

### Known limitation

Per-process effects (`renice`, I/O priority) apply to the reaper, not to the
game it launches. System-wide effects — `gaming-boost`, governor, GPU
performance level, screensaver inhibit — work fully. Registering the game
process beneath the reaper is a possible extension if renice proves to matter.

## Failure behaviour

- gamemoded not running: `busctl` fails, the PID is retried next pass.
- Watcher dead: games run without GameMode, as today; `Restart=on-failure`
  brings it back, and re-registration is idempotent.
- A game that also has `gamemoderun %command%`: the game process registers
  itself separately; GameMode ends once both PIDs are gone. No conflict.
- Up to 2 seconds of a game's start runs without GameMode.

## Testing

1. `just build raider`.
2. After deploy, launch a Steam game: `gamemoded -s` reports active,
   `systemctl status gaming-boost` is active, and
   `journalctl --user -u gamemode-steam-watch` shows the registration.
3. `systemctl --user restart gamemode-steam-watch` mid-game: GameMode stays
   active.
4. Quit the game: within ~5 seconds `gamemoded -s` reports inactive and
   `gaming-boost` is stopped.
