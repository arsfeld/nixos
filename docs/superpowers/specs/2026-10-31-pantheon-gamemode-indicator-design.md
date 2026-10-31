# GameMode indicator for Pantheon

## Problem

GameMode now switches on for every Steam game by itself
(`2026-10-31-gamemode-steam-auto-design.md`), and with it `gaming-boost`, the
CPU governor and the GPU performance level. Nothing on screen says so. macOS
shows a controller icon in the menu bar while Game Mode is on, and clicking it
says which game turned it on. Pantheon should do the same.

Goal: on Pantheon hosts with `constellation.gaming`, a controller icon sits in
Wingpanel exactly while gamemoded has at least one registered game, and its
popover names the running game(s).

Out of scope, by decision: a "Turn Off Game Mode" toggle, and any desktop
notification on activation. The indicator is read-only.

## Rejected alternatives

- **A StatusNotifierItem through namarupa.** Quicker to write, but it renders
  inside the AppIndicator cluster with a DBusMenu rather than a native popover,
  and adds a long-running user process. The point of the feature is the native
  look.
- **Showing gamemoded's `Executable` as the game name.** Steam games are
  registered through their `reaper` process (`gamemode-steam-watch`), so every
  Steam game would read `reaper`.

## Design

### Components and placement

A native Wingpanel indicator plugin, source in
`modules/constellation/pantheon-gamemode/`:

- `src/Indicator.vala` — the `Wingpanel.Indicator` subclass: panel icon,
  popover, visibility.
- `src/GameList.vala` — gamemoded client and game-name resolution.
- `meson.build`, `default.nix` — builds against `pantheon.wingpanel` (8.0.4),
  GTK3, granite and gio, and installs into `lib/wingpanel/`.
- `CLAUDE.md` — the visual loop for this indicator; points at
  `modules/constellation/pantheon-dock/CLAUDE.md` for screenshot and
  lock-screen details instead of repeating them.

It lives beside `pantheon-dock/` rather than in `packages/` because nothing
outside Pantheon uses it.

Wiring is one block in `modules/constellation/gaming.nix`:
`lib.mkIf (cfg.enable && config.services.desktopManager.pantheon.enable)`
adds the package to `services.desktopManager.pantheon.extraWingpanelIndicators`.
That covers raider and blackbird today. `desktop.nix` is unchanged.

The code name is `gamemode`. Wingpanel's `IndicatorSorter` gives unknown code
names order 1: right of the AppIndicator tray, left of the system indicators
(accessibility, sound, network, …), where macOS puts its menu extras. No patch
to Wingpanel is needed.

The panel icon is `input-gaming-symbolic`. The popover is a header "Game Mode",
the line "On", then one row per running game.

### Watching gamemoded

- `get_indicator()` returns `null` for the `GREETER` server type, so nothing
  loads on the login screen.
- In the session, `Bus.watch_name` on `com.feralinteractive.GameMode` with
  `DO_NOT_AUTO_START`: the panel never starts gamemoded. On appear, an async
  `DBusProxy` on `/com/feralinteractive/GameMode` reads `ClientCount`; updates
  come from `PropertiesChanged`, which gamemoded emits for it
  (`SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE` in 1.8.2). On vanish, the count is 0.
- `visible = ClientCount > 0`. Wingpanel drops a hidden indicator's entry, so
  nothing is reserved in the panel while GameMode is off.
- Each transition logs one `info` line: `GameMode on: <n> game(s)` or
  `GameMode off`. The VM test reads these.

### The game list

Built when the popover opens (`opened()`), never from a signal handler:
`ListGames` returns `a(io)`; read `Executable` from each game object, then
name each entry:

1. If the executable's basename is `reaper`, read `/proc/<pid>/cmdline` (same
   user, readable) and take `AppId=<id>`. Look for `appmanifest_<id>.acf` in
   `~/.local/share/Steam/steamapps` and in each `"path"` from that directory's
   `libraryfolders.vdf` (`<path>/steamapps/appmanifest_<id>.acf`), and use its
   `"name"` value. A regex per key suffices; no VDF parser.
2. Otherwise, the executable's basename (gamemoderun, Lutris).
3. Any failed step — unreadable cmdline, no AppId, no manifest, no `"name"`,
   process already gone — falls back to `Steam game <id>`, or to the basename
   if there is no id. Every registered game yields a row.

Resolution functions take paths and strings, not `/proc` directly, so they are
unit-testable. File reads are synchronous and small and happen only on popover
open, for at most a handful of games.

### Failure behaviour

- gamemoded not running or crashed: icon hidden.
- `ListGames` or a property read fails: the popover shows the header and "On"
  with no rows.
- All D-Bus calls are async, so the panel's main loop never blocks on
  gamemoded.
- The plugin runs inside Wingpanel, so a crash takes the panel with it: every
  lookup returns a nullable result and nothing indexes blindly into `/proc`
  output or file contents.

### Test hook

`GAMEMODE_INDICATOR_OPEN=1` pops the popover about 1.5 s after the icon
becomes visible, following the dock's `DOCK_STACKS_OPEN` convention, so the
popover can be built in the VM test and screenshotted on raider without input
injection.

## Testing

1. **Unit tests** (meson `test()`, run in the derivation's `checkPhase`) on
   fixtures: reaper cmdline → AppId; `libraryfolders.vdf` with a second
   library → manifest found there; missing manifest → `Steam game <id>`;
   non-reaper executable → basename.
2. **VM test** `tests/pantheon-gamemode-test.nix`, exposed as
   `checks.x86_64-linux.pantheon-gamemode`, modelled on
   `pantheon-dock-test` (LightDM autologin, `pantheon-wayland`), with
   gamemode enabled, the indicator added and `GAMEMODE_INDICATOR_OPEN=1` in
   the session environment. Asserts from the journal:
   - wingpanel runs and loads the plugin, with no crash and no `critical`;
   - `gamemoderun sleep 30` as alice → `GameMode on: 1 game(s)`;
   - the popover (opened by the hook) builds a row for `sleep`;
   - after the process exits → `GameMode off` within gamemoded's 5 s reaper
     interval (with margin).
3. **Visual loop on raider:** a new `just pantheon::panel-run` builds this
   checkout's indicator, links the session's `$WINGPANEL_INDICATORS_PATH`
   contents plus the new plugin into a temp directory, and restarts wingpanel
   with `WINGPANEL_INDICATORS_PATH` pointed at it, in one breath, then checks
   exactly one panel runs (the session respawns it, as with the dock). Then
   `gamemoderun sleep 120` and `just pantheon::shot` on the panel's top right.
4. **Acceptance after deploy:** launch a Steam game; the icon appears within
   about 2 s (the watcher's poll), the popover shows the game's Steam name,
   and the icon disappears within about 5 s of quitting.
