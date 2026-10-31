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

A native Wingpanel indicator plugin, `libgamemode-indicator.so`, source and
derivation in `packages/wingpanel-indicator-gamemode/`:

- `src/Indicator.vala` — the `Wingpanel.Indicator` subclass: panel icon,
  popover, visibility, and the `get_indicator` entry point.
- `src/Client.vala` — gamemoded client: `count`, and the registered games.
- `src/Names.vala` — game-name resolution, pure functions over strings and
  paths.
- `tests/TestNames.vala` — unit tests for `Names.vala`.
- `meson.build`, `default.nix` — builds against `pantheon.wingpanel` (8.0.4),
  GTK3, gio and libgee, installs into `lib/wingpanel/`, and runs the unit
  tests in `checkPhase`.
- `CLAUDE.md` — the visual loop for this indicator; points at
  `modules/constellation/pantheon-dock/CLAUDE.md` for screenshot and
  lock-screen details instead of repeating them.

It lives in `packages/`, not beside `pantheon-dock/`, because haumea loads
every `.nix` file under `modules/` as a NixOS module, so a derivation there
would be imported as one; `packages/` also makes it
`.#nixosConfigurations.raider.pkgs.wingpanel-indicator-gamemode` for the
visual loop.

Wiring is its own module, `modules/constellation/pantheon-gamemode.nix`,
gated on `programs.gamemode.enable && services.desktopManager.pantheon.enable`
(raider and blackbird today, via `constellation.gaming` and the Pantheon
variant). It adds the package to
`services.desktopManager.pantheon.extraWingpanelIndicators` with
`pkgs.callPackage`, so the VM test can import the module alone without the
flake's overlay, as `pantheon-dock-test` does. `gaming.nix` and `desktop.nix`
are unchanged.

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
- Each change logs one `message` line (not `info`, which GLib hides by
  default): `GameMode on: <n> game(s)` or `GameMode off`. Each popover
  refresh logs `Game Mode games: <names, comma-separated>`. The VM test reads
  these from the journal.

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

### Opening the popover without input

No test hook is needed: Wingpanel itself exports an `open-indicator` action
(`org.gtk.Actions` on `org.elementary.wingpanel`,
`/org/elementary/wingpanel`) taking a code name, and `close-indicator`
likewise. The VM test and the visual loop both open the popover with it,
which also exercises the real `opened()` path.

## Testing

1. **Unit tests** (meson `test()`, run in the derivation's `checkPhase`) on
   fixtures: reaper cmdline → AppId; `libraryfolders.vdf` with a second
   library → manifest found there; missing manifest → `Steam game <id>`;
   non-reaper executable → basename.
2. **VM test** `tests/pantheon-gamemode-test.nix`, exposed as
   `checks.x86_64-linux.pantheon-gamemode-test`, modelled on
   `pantheon-dock-test` (LightDM autologin, `pantheon-wayland`), with
   gamemode enabled and the module imported. Two fake games, both small C
   binaries run under `gamemoderun`: `fake-game`, and one named `reaper` run
   as `reaper SteamLaunch AppId=4242 -- …` with a matching
   `appmanifest_4242.acf` naming it "Fake Quest". (A C binary, because
   nixpkgs' coreutils is multicall, so `sleep` would register as
   `coreutils`.) Asserts from the journal:
   - wingpanel loads the plugin (its `list-indicators` state names
     `gamemode`), and nothing says GameMode is on;
   - `fake-game` → `GameMode on: 1 game(s)`; `open-indicator` → a
     `Game Mode games:` line naming `fake-game`;
   - the reaper → `GameMode on: 2 game(s)`; reopening names `Fake Quest`;
   - both killed → `GameMode off` (gamemoded's reaper runs every 5 s);
   - no warning or critical from the indicator's log domain, and wingpanel
     kept its PID throughout.
3. **Visual loop on raider:** a new `just pantheon::panel-run` builds this
   checkout's indicator, links the session's `$WINGPANEL_INDICATORS_PATH`
   contents plus the new plugin into a temp directory, and restarts wingpanel
   with `WINGPANEL_INDICATORS_PATH` pointed at it, in one breath, then checks
   exactly one panel runs (gala respawns it, as with the dock). Then
   `gamemoderun sleep 120`, the `open-indicator` action, and
   `just pantheon::shot` on the panel's top right.
4. **Acceptance after deploy:** launch a Steam game; the icon appears within
   about 2 s (the watcher's poll), the popover shows the game's Steam name,
   and the icon disappears within about 5 s of quitting.
