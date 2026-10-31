# Pantheon GameMode Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Wingpanel indicator that shows a controller icon exactly while gamemoded has a registered game, with a popover naming the running game(s), Steam games by their real name.

**Architecture:** A Vala Wingpanel plugin (`libgamemode-indicator.so`) in `packages/wingpanel-indicator-gamemode/`, split into pure name resolution (`Names.vala`, unit-tested in `checkPhase`), a gamemoded D-Bus client (`Client.vala`) and the indicator UI (`Indicator.vala`). A standalone NixOS module adds it to Pantheon's `extraWingpanelIndicators` wherever GameMode and Pantheon are both enabled. A NixOS VM test drives it with fake games; a `just pantheon::panel-run` recipe swaps it into raider's live panel for visual checks.

**Tech Stack:** Vala, meson, GTK3, gio (GDBus), Wingpanel 8.0.4, gamemode 1.8.2 D-Bus API, Nix (`stdenv.mkDerivation`, `testers.nixosTest`), just.

**Spec:** `docs/superpowers/specs/2026-10-31-pantheon-gamemode-indicator-design.md`

## Global Constraints

- Commit straight to `master`; no branches or worktrees.
- Conventional commits, scope `modules` (e.g. `feat(modules): …`). Never mention Claude.
- Run `just fmt` before committing any `.nix` change (CI's format check uses alejandra).
- New files are invisible to `nix build` until `git add`ed (`git add -N` is enough).
- Read-only: no turn-off toggle, no notifications.
- Indicator code name: `gamemode`. Panel icon: `input-gaming-symbolic` (present in elementary-icon-theme 9.0.0). Library: `libgamemode-indicator.so`. Log domain: `io.elementary.wingpanel.gamemode`.
- Exact log lines (tests grep them): `GameMode on: <n> game(s)`, `GameMode off`, `Game Mode games: <name>, <name>`. Use `message()`, never `info()`/`debug()` (hidden by default).
- Never start gamemoded from the panel (`BusNameWatcherFlags.NONE`, `DBusProxyFlags.DO_NOT_AUTO_START`). Never return an indicator for the greeter.
- Never inject input on raider (see `modules/constellation/pantheon-dock/CLAUDE.md`).
- Popover shape: header "Game Mode", dim line "On", separator, one label per game.

---

### Task 1: Name resolution with unit tests, and the package skeleton

**Files:**
- Create: `packages/wingpanel-indicator-gamemode/default.nix`
- Create: `packages/wingpanel-indicator-gamemode/meson.build`
- Create: `packages/wingpanel-indicator-gamemode/src/Names.vala`
- Test: `packages/wingpanel-indicator-gamemode/tests/TestNames.vala`

**Interfaces:**
- Produces (namespace `GameModeIndicator.Names`):
  - `string[] split_cmdline (uint8[] data)` — splits NUL-separated `/proc/<pid>/cmdline`.
  - `string? app_id_from_args (string[] args)` — the digits of the first `AppId=<digits>` before `--`, else `null`.
  - `string[] vdf_values (string text, string key)` — every `"key" "value"` value in VDF text, unescaped.
  - `string[] steamapps_dirs (string steamapps)` — `steamapps` plus `<path>/steamapps` for each `"path"` in its `libraryfolders.vdf`.
  - `string? steam_name (string app_id, string[] dirs)` — `"name"` from the first `appmanifest_<id>.acf` found in `dirs`.
  - `string display_name (string executable, string[]? args, string[] dirs)` — basename unless it is `reaper`; reaper → Steam name, else `Steam game <id>`, else `reaper`.
- Produces: package attribute `pkgs.wingpanel-indicator-gamemode` (via the haumea overlay on hosts) and callable as `pkgs.callPackage ../../packages/wingpanel-indicator-gamemode {}`.

- [ ] **Step 1: Write the failing tests**

`packages/wingpanel-indicator-gamemode/tests/TestNames.vala`:

```vala
/*
 * Unit tests for Names.vala, run by `meson test` in the package's checkPhase.
 * Steam trees are built under a fresh temporary directory per test.
 */
using GameModeIndicator;

uint8[] nul_joined (string[] parts) {
    uint8[] result = {};
    foreach (unowned string part in parts) {
        foreach (uint8 b in part.data) {
            result += b;
        }
        result += 0;
    }
    return result;
}

string tmp_tree () {
    try {
        return DirUtils.make_tmp ("gamemode-indicator-XXXXXX");
    } catch (FileError e) {
        error ("make_tmp: %s", e.message);
    }
}

void write (string path, string text) {
    DirUtils.create_with_parents (Path.get_dirname (path), 0755);
    try {
        FileUtils.set_contents (path, text);
    } catch (FileError e) {
        error ("write %s: %s", path, e.message);
    }
}

string manifest (string id, string name) {
    return "\"AppState\"\n{\n\t\"appid\"\t\t\"%s\"\n\t\"name\"\t\t\"%s\"\n\t\"installdir\"\t\t\"x\"\n}\n".printf (id, name);
}

int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/names/split-cmdline", () => {
        var parts = Names.split_cmdline (nul_joined ({ "reaper", "SteamLaunch", "AppId=620", "--", "/game" }));
        assert_cmpint (parts.length, CompareOperator.EQ, 5);
        assert_cmpstr (parts[2], CompareOperator.EQ, "AppId=620");
        assert_cmpstr (parts[4], CompareOperator.EQ, "/game");
    });

    Test.add_func ("/names/split-cmdline-no-trailing-nul", () => {
        var data = nul_joined ({ "a", "b" });
        var parts = Names.split_cmdline (data[0:data.length - 1]);
        assert_cmpint (parts.length, CompareOperator.EQ, 2);
        assert_cmpstr (parts[1], CompareOperator.EQ, "b");
    });

    Test.add_func ("/names/app-id", () => {
        assert_cmpstr (Names.app_id_from_args ({ "reaper", "SteamLaunch", "AppId=620", "--", "x" }), CompareOperator.EQ, "620");
        // After `--` the arguments belong to the game.
        assert_cmpstr (Names.app_id_from_args ({ "reaper", "--", "AppId=620" }), CompareOperator.EQ, null);
        // Digits only: the id becomes part of a file name.
        assert_cmpstr (Names.app_id_from_args ({ "reaper", "AppId=../x" }), CompareOperator.EQ, null);
        assert_cmpstr (Names.app_id_from_args ({ "reaper", "AppId=" }), CompareOperator.EQ, null);
    });

    Test.add_func ("/names/vdf-escapes", () => {
        var values = Names.vdf_values ("\"name\"\t\t\"Foo \\\"Bar\\\"\"\n\"names\"\t\"no\"\n", "name");
        assert_cmpint (values.length, CompareOperator.EQ, 1);
        assert_cmpstr (values[0], CompareOperator.EQ, "Foo \"Bar\"");
    });

    Test.add_func ("/names/main-library", () => {
        var steamapps = Path.build_filename (tmp_tree (), "steamapps");
        write (Path.build_filename (steamapps, "appmanifest_620.acf"), manifest ("620", "Portal 2"));
        var dirs = Names.steamapps_dirs (steamapps);
        assert_cmpstr (Names.display_name ("/x/ubuntu12_32/reaper", { "reaper", "SteamLaunch", "AppId=620", "--", "g" }, dirs), CompareOperator.EQ, "Portal 2");
    });

    Test.add_func ("/names/second-library", () => {
        var root = tmp_tree ();
        var steamapps = Path.build_filename (root, "steamapps");
        var library = Path.build_filename (root, "games");
        write (Path.build_filename (steamapps, "libraryfolders.vdf"),
            "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"%s\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"%s\"\n\t}\n}\n".printf (root, library));
        write (Path.build_filename (library, "steamapps", "appmanifest_1091500.acf"), manifest ("1091500", "Cyberpunk 2077"));
        var dirs = Names.steamapps_dirs (steamapps);
        assert_cmpint (dirs.length, CompareOperator.EQ, 3);
        assert_cmpstr (Names.steam_name ("1091500", dirs), CompareOperator.EQ, "Cyberpunk 2077");
    });

    Test.add_func ("/names/fallbacks", () => {
        var dirs = Names.steamapps_dirs (Path.build_filename (tmp_tree (), "steamapps"));
        assert_cmpstr (Names.display_name ("/x/reaper", { "reaper", "AppId=999" }, dirs), CompareOperator.EQ, "Steam game 999");
        assert_cmpstr (Names.display_name ("/x/reaper", null, dirs), CompareOperator.EQ, "reaper");
        assert_cmpstr (Names.display_name ("/nix/store/abc-game/bin/witcher3", null, dirs), CompareOperator.EQ, "witcher3");
    });

    return Test.run ();
}
```

`packages/wingpanel-indicator-gamemode/meson.build` (test target only for now):

```meson
project('wingpanel-indicator-gamemode', 'vala', 'c', version: '0.1.0')

add_project_arguments('-DG_LOG_DOMAIN="io.elementary.wingpanel.gamemode"', language: 'c')

glib_dep = dependency('glib-2.0')
gobject_dep = dependency('gobject-2.0')

test('names', executable(
    'test-names',
    'src/Names.vala',
    'tests/TestNames.vala',
    dependencies: [glib_dep, gobject_dep],
))
```

`packages/wingpanel-indicator-gamemode/default.nix`:

```nix
# Wingpanel indicator showing GameMode's state, macOS-style: a controller icon
# while gamemoded has a registered game, and a popover naming the game(s).
# Added to Pantheon by modules/constellation/pantheon-gamemode.nix.
# Design: docs/superpowers/specs/2026-10-31-pantheon-gamemode-indicator-design.md
{pkgs, ...}:
pkgs.stdenv.mkDerivation {
  pname = "wingpanel-indicator-gamemode";
  version = "0.1.0";

  # Only the sources, so editing this file or CLAUDE.md does not rebuild it.
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [./meson.build ./src ./tests];
  };

  nativeBuildInputs = with pkgs; [meson ninja pkg-config vala];
  buildInputs = with pkgs; [glib gtk3 libgee pantheon.wingpanel];

  # Runs tests/TestNames.vala.
  doCheck = true;

  meta = {
    description = "GameMode indicator for Wingpanel";
    license = pkgs.lib.licenses.gpl3Plus;
    platforms = pkgs.lib.platforms.linux;
  };
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
git add -N packages/wingpanel-indicator-gamemode
nix build .#nixosConfigurations.raider.pkgs.wingpanel-indicator-gamemode -L
```

Expected: FAIL — meson reports `File src/Names.vala does not exist`.

- [ ] **Step 3: Write the implementation**

`packages/wingpanel-indicator-gamemode/src/Names.vala`:

```vala
/*
 * Turns a game gamemoded registered into the name the popover shows.
 *
 * Steam registers every game through its `reaper` process (gamemode-steam-watch
 * in modules/constellation/gaming.nix), so gamemoded's Executable reads
 * `reaper` for all of them. A reaper is named from Steam's app manifest
 * instead, using the AppId on its command line; anything else by its
 * executable's basename. Every lookup that fails falls back to a plainer
 * name, never to nothing.
 *
 * These take strings and paths, never /proc or $HOME, so tests can feed them.
 */
namespace GameModeIndicator.Names {
    /* /proc/<pid>/cmdline is NUL-separated, usually with a trailing NUL. */
    public string[] split_cmdline (uint8[] data) {
        string[] args = {};
        var current = new StringBuilder ();
        foreach (uint8 b in data) {
            if (b == 0) {
                args += current.str;
                current.truncate (0);
            } else {
                current.append_c ((char) b);
            }
        }
        if (current.len > 0) {
            args += current.str;
        }
        return args;
    }

    /* Steam starts games as `reaper SteamLaunch AppId=<id> -- <game…>`. */
    public string? app_id_from_args (string[] args) {
        foreach (unowned string arg in args) {
            if (arg == "--") {
                break;
            }
            if (arg.has_prefix ("AppId=")) {
                var id = arg.substring ("AppId=".length);
                return is_digits (id) ? id : null;
            }
        }
        return null;
    }

    /* The id goes into a file name, so anything but digits is rejected. */
    private bool is_digits (string text) {
        if (text == "") {
            return false;
        }
        for (int i = 0; i < text.length; i++) {
            if (!text[i].isdigit ()) {
                return false;
            }
        }
        return true;
    }

    /*
     * Every value of a `"key" "value"` pair in Valve's KeyValues text, with
     * VDF's C-style escapes undone. A regex per key is enough for the two
     * keys read here; there is no VDF parser.
     */
    public string[] vdf_values (string text, string key) {
        string[] values = {};
        try {
            var regex = new Regex ("\"%s\"\\s+\"((?:[^\"\\\\]|\\\\.)*)\"".printf (Regex.escape_string (key)));
            MatchInfo info;
            if (regex.match (text, 0, out info)) {
                do {
                    values += info.fetch (1).compress ();
                } while (info.next ());
            }
        } catch (RegexError e) {
            warning ("Could not read VDF key %s: %s", key, e.message);
        }
        return values;
    }

    /*
     * The main steamapps directory plus every library Steam lists in its
     * libraryfolders.vdf. The main library usually appears there too; looking
     * twice is harmless.
     */
    public string[] steamapps_dirs (string steamapps) {
        string[] dirs = { steamapps };
        string text;
        try {
            FileUtils.get_contents (Path.build_filename (steamapps, "libraryfolders.vdf"), out text);
        } catch (FileError e) {
            return dirs;
        }
        foreach (var path in vdf_values (text, "path")) {
            dirs += Path.build_filename (path, "steamapps");
        }
        return dirs;
    }

    public string? steam_name (string app_id, string[] dirs) {
        foreach (unowned string dir in dirs) {
            string text;
            try {
                FileUtils.get_contents (Path.build_filename (dir, "appmanifest_%s.acf".printf (app_id)), out text);
            } catch (FileError e) {
                continue;
            }
            var names = vdf_values (text, "name");
            if (names.length > 0 && names[0] != "") {
                return names[0];
            }
        }
        return null;
    }

    /* `args` is the game process's command line, or null if unreadable. */
    public string display_name (string executable, string[]? args, string[] dirs) {
        var basename = Path.get_basename (executable);
        if (basename != "reaper" || args == null) {
            return basename;
        }
        var id = app_id_from_args (args);
        if (id == null) {
            return basename;
        }
        return steam_name (id, dirs) ?? "Steam game %s".printf (id);
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
nix build .#nixosConfigurations.raider.pkgs.wingpanel-indicator-gamemode -L 2>&1 | grep -E 'names|Ok:|Fail:'
```

Expected: `names  OK`, `Ok: 1`, `Fail: 0`. If a single sub-test fails, the log shows its `/names/...` path; fix `Names.vala`, not the test, unless the test contradicts the spec.

- [ ] **Step 5: Commit**

```bash
just fmt
git add packages/wingpanel-indicator-gamemode
git commit -m "feat(modules): resolve GameMode game names for a Wingpanel indicator"
```

---

### Task 2: The indicator, its module, and the VM test

**Files:**
- Create: `packages/wingpanel-indicator-gamemode/src/Client.vala`
- Create: `packages/wingpanel-indicator-gamemode/src/Indicator.vala`
- Modify: `packages/wingpanel-indicator-gamemode/meson.build` (add the shared module)
- Create: `modules/constellation/pantheon-gamemode.nix`
- Create: `tests/pantheon-gamemode-test.nix`
- Modify: `flake-modules/checks.nix` (next to `pantheon-dock-test`, in the `optionalAttrs (system == "x86_64-linux")` block)

**Interfaces:**
- Consumes: `Names.split_cmdline`, `Names.steamapps_dirs`, `Names.display_name` from Task 1.
- Produces:
  - `public struct GameModeIndicator.Game { public int pid; public string executable; }`
  - `public class GameModeIndicator.Client : Object` with `public int count { get; private set; }` (notifies on change) and `public async Game[] list_games ()`.
  - `public class GameModeIndicator.Indicator : Wingpanel.Indicator`, code name `gamemode`.
  - The flake check `checks.x86_64-linux.pantheon-gamemode-test`.

- [ ] **Step 1: Write the failing VM test**

`tests/pantheon-gamemode-test.nix`:

```nix
# Boots Pantheon with the GameMode indicator (modules/constellation/pantheon-gamemode.nix)
# and drives it with two fake games under gamemoderun: fake-game, named by its
# executable, and a binary named `reaper` launched the way Steam launches games,
# named from a Steam app manifest. Both are C, not `sleep`: nixpkgs' coreutils
# is multicall, so gamemoded would see every coreutils tool as `coreutils`.
# Wingpanel's own open-indicator action opens the popover, so nothing is
# clicked. The indicator logs each change and the names it shows; this asserts
# on those lines. Modelled on pantheon-dock-test.
{pkgs, ...}: let
  sleeper = name:
    pkgs.writeCBin name ''
      #include <unistd.h>
      int main(void) { sleep(600); return 0; }
    '';
  wingpanelAction = pkgs.writeShellScriptBin "wingpanel-action" ''
    exec ${pkgs.glib.bin}/bin/gdbus call --session --dest org.elementary.wingpanel \
      --object-path /org/elementary/wingpanel --method org.gtk.Actions.Activate \
      "$1-indicator" "[<'gamemode'>]" '{}'
  '';
in {
  name = "pantheon-gamemode";

  nodes.machine = {...}: {
    imports = [
      "${pkgs.path}/nixos/tests/common/user-account.nix"
      ../modules/constellation/pantheon-gamemode.nix
    ];

    # Workaround ".gala-wrapped invoked oom-killer" (as upstream's test).
    virtualisation.memorySize = 2047;

    services.xserver.enable = true;
    services.desktopManager.pantheon.enable = true;
    services.displayManager = {
      defaultSession = "pantheon-wayland";
      autoLogin = {
        enable = true;
        user = "alice";
      };
    };

    programs.gamemode.enable = true;
    environment.systemPackages = [(sleeper "fake-game") (sleeper "reaper") wingpanelAction];
    environment.etc."fake-steam/appmanifest_4242.acf".text = ''
      "AppState"
      {
      	"appid"		"4242"
      	"name"		"Fake Quest"
      	"installdir"		"FakeQuest"
      }
    '';
  };

  testScript = {nodes, ...}: let
    user = nodes.machine.users.users.alice;
    bus = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString user.uid}/bus";
    panel = "pgrep -f '(^|/)io\\.elementary\\.wingpanel$'";
    log = "journalctl -b -t io.elementary.wingpanel";
  in ''
    def as_alice(cmd):
        return machine.succeed(f"su - alice -c '${bus} {cmd}'")

    machine.wait_for_unit("display-manager.service")
    machine.wait_for_file("/run/user/${toString user.uid}/wayland-0")

    with subtest("Wingpanel loads the indicator, hidden while no game runs"):
        machine.wait_until_succeeds("${panel}")
        machine.wait_until_succeeds(
            "su - alice -c '${bus} gdbus call --session --dest org.elementary.wingpanel "
            "--object-path /org/elementary/wingpanel --method org.gtk.Actions.DescribeAll' | grep -q gamemode"
        )
        panel_pid = machine.succeed("${panel}").strip()
        machine.fail("${log} | grep 'GameMode on'")

    with subtest("A game turns it on, and the popover names it"):
        as_alice("gamemoderun fake-game >/dev/null 2>&1 &")
        machine.wait_until_succeeds("${log} | grep -q 'GameMode on: 1 game(s)'")
        as_alice("wingpanel-action open")
        machine.wait_until_succeeds("${log} | grep -q 'Game Mode games: fake-game$'")
        machine.screenshot("gamemode_popover")
        as_alice("wingpanel-action close")

    with subtest("A Steam game is named from its app manifest"):
        as_alice("mkdir -p ~/.local/share/Steam/steamapps && cp /etc/fake-steam/appmanifest_4242.acf ~/.local/share/Steam/steamapps/")
        as_alice("gamemoderun reaper SteamLaunch AppId=4242 -- /fake/game >/dev/null 2>&1 &")
        machine.wait_until_succeeds("${log} | grep -q 'GameMode on: 2 game(s)'")
        as_alice("wingpanel-action open")
        machine.wait_until_succeeds("${log} | grep 'Game Mode games:' | grep -q 'Fake Quest'")
        machine.screenshot("gamemode_popover_steam")
        as_alice("wingpanel-action close")

    with subtest("It turns off once the games exit"):
        machine.succeed("pkill -x fake-game; pkill -x reaper")
        # gamemoded notices dead PIDs on its 5 s reaper pass.
        machine.wait_until_succeeds("${log} | grep -q 'GameMode off'", timeout=60)

    with subtest("The indicator logged no warning and the panel never restarted"):
        machine.fail("journalctl -b -q GLIB_DOMAIN=io.elementary.wingpanel.gamemode -p warning | grep .")
        assert machine.succeed("${panel}").strip() == panel_pid, "wingpanel restarted"
  '';
}
```

`modules/constellation/pantheon-gamemode.nix`:

```nix
# macOS-style GameMode indicator in Pantheon's Wingpanel: a controller icon
# while gamemoded has a registered game, with a popover naming the game(s).
# Package: packages/wingpanel-indicator-gamemode.
# Design: docs/superpowers/specs/2026-10-31-pantheon-gamemode-indicator-design.md
#
# Gated on the two upstream options rather than constellation.*, so the VM test
# (tests/pantheon-gamemode-test.nix) can import this module alone; callPackage
# rather than the flake overlay's attribute for the same reason.
{
  config,
  lib,
  pkgs,
  ...
}: {
  config = lib.mkIf (config.programs.gamemode.enable && config.services.desktopManager.pantheon.enable) {
    services.desktopManager.pantheon.extraWingpanelIndicators = [
      (pkgs.callPackage ../../packages/wingpanel-indicator-gamemode {})
    ];
  };
}
```

In `flake-modules/checks.nix`, directly after the `pantheon-dock-test` entry:

```nix
        pantheon-gamemode-test = inputs.nixpkgs.legacyPackages.${system}.testers.nixosTest (
          import ../tests/pantheon-gamemode-test.nix
        );
```

- [ ] **Step 2: Run the VM test to verify it fails**

```bash
git add -N tests/pantheon-gamemode-test.nix modules/constellation/pantheon-gamemode.nix
nix build .#checks.x86_64-linux.pantheon-gamemode-test -L
```

Expected: FAIL in subtest "Wingpanel loads the indicator" — the package installs no plugin yet, so `DescribeAll` never lists `gamemode` (the build itself succeeds; only the test target exists).

- [ ] **Step 3: Write the client**

`packages/wingpanel-indicator-gamemode/src/Client.vala`:

```vala
/*
 * Follows gamemoded on the session bus. `count` is its ClientCount, the number
 * of registered games, or 0 while gamemoded is not running. It never starts
 * gamemoded: gamemoded's absence just means no game is running.
 */
public struct GameModeIndicator.Game {
    public int pid;
    public string executable;
}

public class GameModeIndicator.Client : Object {
    private const string NAME = "com.feralinteractive.GameMode";
    private const string PATH = "/com/feralinteractive/GameMode";
    private const string IFACE = "com.feralinteractive.GameMode";
    private const string GAME_IFACE = "com.feralinteractive.GameMode.Game";
    private const int TIMEOUT_MS = 1000;

    public int count { get; private set; default = 0; }

    private DBusProxy? proxy = null;
    // Bumped on every appear/vanish, so a proxy that finishes connecting after
    // gamemoded has already gone again is dropped instead of kept.
    private uint generation = 0;

    construct {
        Bus.watch_name (BusType.SESSION, NAME, BusNameWatcherFlags.NONE, on_appeared, on_vanished);
    }

    private void on_appeared (DBusConnection connection, string name, string owner) {
        connect_proxy.begin (connection, ++generation);
    }

    private void on_vanished (DBusConnection? connection, string name) {
        generation++;
        proxy = null;
        count = 0;
    }

    private async void connect_proxy (DBusConnection connection, uint my_generation) {
        try {
            var p = yield new DBusProxy (connection, DBusProxyFlags.DO_NOT_AUTO_START, null, NAME, PATH, IFACE, null);
            if (my_generation != generation) {
                return;
            }
            // gamemoded emits PropertiesChanged for ClientCount (EMITS_CHANGE).
            p.g_properties_changed.connect (() => read_count (p));
            proxy = p;
            read_count (p);
        } catch (Error e) {
            warning ("Could not follow gamemoded: %s", e.message);
        }
    }

    private void read_count (DBusProxy p) {
        var value = p.get_cached_property ("ClientCount");
        count = (value != null && value.is_of_type (VariantType.INT32)) ? value.get_int32 () : 0;
    }

    /* Every registered game. Empty if gamemoded is gone or the call fails. */
    public async Game[] list_games () {
        Game[] games = {};
        var p = proxy;
        if (p == null) {
            return games;
        }
        var connection = p.get_connection ();
        try {
            var reply = yield connection.call (NAME, PATH, IFACE, "ListGames", null,
                new VariantType ("(a(io))"), DBusCallFlags.NONE, TIMEOUT_MS, null);
            var list = reply.get_child_value (0);
            for (size_t i = 0; i < list.n_children (); i++) {
                var entry = list.get_child_value (i);
                var exe = yield executable (connection, entry.get_child_value (1).get_string ());
                if (exe != null) {
                    Game game = { entry.get_child_value (0).get_int32 (), exe };
                    games += game;
                }
            }
        } catch (Error e) {
            warning ("Could not list GameMode games: %s", e.message);
        }
        return games;
    }

    /* Null when the game unregistered between ListGames and this call. */
    private async string? executable (DBusConnection connection, string path) {
        try {
            var reply = yield connection.call (NAME, path, "org.freedesktop.DBus.Properties", "Get",
                new Variant ("(ss)", GAME_IFACE, "Executable"),
                new VariantType ("(v)"), DBusCallFlags.NONE, TIMEOUT_MS, null);
            var value = reply.get_child_value (0).get_variant ();
            return value.is_of_type (VariantType.STRING) ? value.get_string () : null;
        } catch (Error e) {
            return null;
        }
    }
}
```

- [ ] **Step 4: Write the indicator**

`packages/wingpanel-indicator-gamemode/src/Indicator.vala`:

```vala
/*
 * macOS-style Game Mode indicator: a controller icon in Wingpanel exactly while
 * gamemoded has a registered game, and a popover naming the game(s). Read-only.
 *
 * Every change of state logs one line ("GameMode on: <n> game(s)",
 * "GameMode off") and every popover refresh logs the names it shows; the VM test
 * (tests/pantheon-gamemode-test.nix) asserts on them, so keep them stable.
 */
public class GameModeIndicator.Indicator : Wingpanel.Indicator {
    private Client client;
    private Gtk.Image? icon = null;
    private Gtk.Box? popover = null;
    private Gtk.Box? games_box = null;

    public Indicator () {
        Object (code_name: "gamemode");
    }

    construct {
        client = new Client ();
        client.notify["count"].connect (() => {
            visible = client.count > 0;
            if (visible) {
                message ("GameMode on: %d game(s)", client.count);
            } else {
                message ("GameMode off");
            }
        });
    }

    public override Gtk.Widget get_display_widget () {
        if (icon == null) {
            icon = new Gtk.Image.from_icon_name ("input-gaming-symbolic", Gtk.IconSize.LARGE_TOOLBAR) {
                tooltip_text = "Game Mode is on"
            };
        }
        return icon;
    }

    public override Gtk.Widget? get_widget () {
        if (popover == null) {
            var title = new Gtk.Label ("Game Mode") {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12
            };
            title.get_style_context ().add_class ("h4");

            var state = new Gtk.Label ("On") {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12
            };
            state.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);

            var separator = new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
                margin_top = 6,
                margin_bottom = 3
            };

            games_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                margin_bottom = 3
            };

            popover = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                width_request = 200
            };
            popover.add (title);
            popover.add (state);
            popover.add (separator);
            popover.add (games_box);
            popover.show_all ();
        }
        return popover;
    }

    public override void opened () {
        refresh.begin ();
    }

    public override void closed () {
    }

    /*
     * Built on open, never from a signal, so a game churning registrations
     * never wakes the panel. Names are resolved before the rows are swapped,
     * so overlapping refreshes just leave the last one's rows.
     */
    private async void refresh () {
        var games = yield client.list_games ();
        var dirs = Names.steamapps_dirs (Path.build_filename (Environment.get_user_data_dir (), "Steam", "steamapps"));
        string[] names = {};
        foreach (var game in games) {
            names += Names.display_name (game.executable, read_cmdline (game.pid), dirs);
        }
        message ("Game Mode games: %s", string.joinv (", ", names));

        if (games_box == null) {
            return;
        }
        games_box.foreach ((child) => child.destroy ());
        foreach (unowned string name in names) {
            games_box.add (new Gtk.Label (name) {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12,
                margin_top = 3,
                margin_bottom = 3,
                ellipsize = Pango.EllipsizeMode.END,
                max_width_chars = 32
            });
        }
        games_box.show_all ();
    }

    /* Null when the process is already gone. */
    private static string[]? read_cmdline (int pid) {
        uint8[] data;
        try {
            FileUtils.get_data ("/proc/%d/cmdline".printf (pid), out data);
        } catch (FileError e) {
            return null;
        }
        return Names.split_cmdline (data);
    }
}

public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.IndicatorManager.ServerType server_type) {
    // Nothing to show on the login screen, and no gamemoded there.
    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }
    return new GameModeIndicator.Indicator ();
}
```

Append to `packages/wingpanel-indicator-gamemode/meson.build`:

```meson

wingpanel_dep = dependency('wingpanel')

shared_module(
    'gamemode-indicator',
    'src/Names.vala',
    'src/Client.vala',
    'src/Indicator.vala',
    dependencies: [
        glib_dep,
        gobject_dep,
        dependency('gio-2.0'),
        dependency('gtk+-3.0'),
        wingpanel_dep,
    ],
    install: true,
    install_dir: wingpanel_dep.get_variable(
        pkgconfig: 'indicatorsdir',
        pkgconfig_define: ['libdir', get_option('prefix') / get_option('libdir')],
    ),
)
```

- [ ] **Step 5: Check the package installs the plugin**

```bash
ls "$(nix build --no-link --print-out-paths .#nixosConfigurations.raider.pkgs.wingpanel-indicator-gamemode)/lib/wingpanel"
```

Expected: `libgamemode-indicator.so`. A Vala compile error here means an API mismatch with the vapi; fix the call, keeping behaviour as specified.

- [ ] **Step 6: Run the VM test to verify it passes**

```bash
nix build .#checks.x86_64-linux.pantheon-gamemode-test -L
```

Expected: all five subtests pass. Then look at the two screenshots in `./result/` (`gamemode_popover.png`, `gamemode_popover_steam.png`) with the Read tool: the controller icon is in the panel's top right and the popover shows "Game Mode", "On" and the game names. If a subtest times out, read the `io.elementary.wingpanel` lines in the build log before changing anything.

- [ ] **Step 7: Check the hosts still evaluate and only Pantheon + GameMode hosts get it**

```bash
for h in raider blackbird galactica; do
  echo "$h: $(nix eval --json .#nixosConfigurations.$h.config.services.desktopManager.pantheon.extraWingpanelIndicators --apply 'map (p: p.pname or p.name)')"
done
```

Expected: raider and blackbird list `wingpanel-indicator-gamemode` beside `elementary-monitor` and namarupa; galactica `[]`.

- [ ] **Step 8: Commit**

```bash
just fmt
git add packages/wingpanel-indicator-gamemode modules/constellation/pantheon-gamemode.nix tests/pantheon-gamemode-test.nix flake-modules/checks.nix
git commit -m "feat(modules): show a GameMode indicator in Pantheon's panel"
```

---

### Task 3: Live visual loop on raider, and its notes

**Files:**
- Modify: `just/pantheon.just` (add `panel-run` after `dock-run`)
- Create: `packages/wingpanel-indicator-gamemode/CLAUDE.md`

**Interfaces:**
- Consumes: `.#nixosConfigurations.raider.pkgs.wingpanel-indicator-gamemode` (Task 1/2), `just pantheon::shot` (existing).
- Produces: `just pantheon::panel-run [log] [VAR=value…]`.

- [ ] **Step 1: Add the recipe**

Append to `just/pantheon.just`:

```just

# Replace the session's panel with one that loads this checkout's GameMode
# indicator in place of the deployed one, passing any VAR=value environment
# through (e.g. G_MESSAGES_DEBUG=all). Logs go to LOG.
[positional-arguments]
panel-run log="/tmp/io.elementary.wingpanel.log" *env:
    #!/usr/bin/env bash
    set -euo pipefail
    indicator=$(nix build --no-link --print-out-paths '{{ justfile_directory() }}#nixosConfigurations.raider.pkgs.wingpanel-indicator-gamemode')
    log="$1"
    shift
    extra=("$@")
    # `pgrep -x` cannot match: the process name is longer than 15 characters.
    pattern='(^|/)io\.elementary\.wingpanel$'
    pid=$(pgrep -f "$pattern" | head -n1) || { echo "no wingpanel is running" >&2; exit 1; }
    exe=$(readlink "/proc/$pid/exe")
    # The running panel's environment, as its nix wrapper and gala set it; ours
    # differs only in WINGPANEL_INDICATORS_PATH, later on the env line, so it wins.
    mapfile -d '' session_env < "/proc/$pid/environ"
    current=$(printf '%s\n' "${session_env[@]}" | sed -n 's/^WINGPANEL_INDICATORS_PATH=//p')
    dir=$(mktemp -d /tmp/wingpanel-indicators.XXXXXX)
    for so in "$current"/*.so; do
        [ "$(basename "$so")" = libgamemode-indicator.so ] || ln -s "$so" "$dir/"
    done
    ln -s "$indicator/lib/wingpanel/libgamemode-indicator.so" "$dir/"
    # gala respawns the panel the moment one dies, and a second panel hands its
    # command line to the first and exits, so kill and start in the same
    # breath, then make sure ours is the one left. `exec -a` keeps the name
    # the pattern above matches.
    pkill -f "$pattern" || true
    env -i "${session_env[@]}" WINGPANEL_INDICATORS_PATH="$dir" "${extra[@]}" \
        setsid "$BASH" -c 'exec -a io.elementary.wingpanel "$0"' "$exe" > "$log" 2>&1 < /dev/null &
    for _ in $(seq 20); do
        sleep 0.5
        pids=$(pgrep -f "$pattern" || true)
        if [ "$(wc -w <<< "$pids")" -eq 1 ] && tr '\0' '\n' < "/proc/$pids/environ" | grep -qxF "WINGPANEL_INDICATORS_PATH=$dir"; then
            echo "running with $indicator"
            exit 0
        fi
    done
    echo "the session's panel won the race; run again" >&2
    pgrep -fa "$pattern" >&2 || true
    exit 1
```

- [ ] **Step 2: Run it on raider and capture the indicator**

```bash
just pantheon::panel-run
gamemoderun sleep 120 >/dev/null 2>&1 &
sleep 3
gdbus call --session --dest org.elementary.wingpanel --object-path /org/elementary/wingpanel \
  --method org.gtk.Actions.Activate open-indicator "[<'gamemode'>]" '{}'
sleep 1
just pantheon::shot /tmp/gamemode-panel.png 2240 0 1200 500
```

Read `/tmp/gamemode-panel.png`. Expected: the panel still spans the top of the screen; the controller icon sits left of the sound/network indicators; the popover reads "Game Mode" / "On" / `coreutils` (nixpkgs' `sleep` is the multicall coreutils binary, which is what gamemoded records). If the restarted panel is not docked at the top (gala may only grant its panel protocol to processes it spawned), note that in the CLAUDE.md below and use `just test raider` for visual checks instead; do not try to work around gala.

Then close it and confirm the icon goes away after the game:

```bash
gdbus call --session --dest org.elementary.wingpanel --object-path /org/elementary/wingpanel \
  --method org.gtk.Actions.Activate close-indicator "[<'gamemode'>]" '{}'
pkill -f '^sleep 120$'; sleep 8
grep -E 'GameMode (on|off)|Game Mode games' /tmp/io.elementary.wingpanel.log
```

Expected: `GameMode on: 1 game(s)`, `Game Mode games: coreutils`, `GameMode off`.

- [ ] **Step 3: Write the notes**

`packages/wingpanel-indicator-gamemode/CLAUDE.md`:

```markdown
# The GameMode Wingpanel indicator

Design: `docs/superpowers/specs/2026-10-31-pantheon-gamemode-indicator-design.md`.
Wired in by `modules/constellation/pantheon-gamemode.nix` wherever GameMode and Pantheon
are both on.

- `src/Names.vala` is pure and unit-tested (`tests/TestNames.vala`, run in `checkPhase`);
  put any new naming rule there with a test, not in `Indicator.vala`.
- The log lines in `Indicator.vala` are asserted by `tests/pantheon-gamemode-test.nix`
  (`nix build .#checks.x86_64-linux.pantheon-gamemode-test -L`). Change both together.
- Fake games must be real binaries: nixpkgs' coreutils is multicall, so `gamemoderun sleep`
  registers as `coreutils`.

## Looking at it on raider

    just pantheon::panel-run                       # this checkout's indicator, live
    gamemoderun sleep 120 &
    gdbus call --session --dest org.elementary.wingpanel --object-path /org/elementary/wingpanel \
      --method org.gtk.Actions.Activate open-indicator "[<'gamemode'>]" '{}'
    just pantheon::shot out.png 2240 0 1200 500

Wingpanel's own `open-indicator`/`close-indicator` actions open the popover, so there is no
test hook and no input injection. Everything about `shot` (locked or blanked screens, why
it is the only capture that works) is in `modules/constellation/pantheon-dock/CLAUDE.md`.
```

If Step 2 found the restarted panel undocked, add that finding under "Looking at it on raider" instead of the `panel-run` line.

- [ ] **Step 4: Commit**

```bash
git add just/pantheon.just packages/wingpanel-indicator-gamemode/CLAUDE.md
git commit -m "feat(modules): swap this checkout's GameMode indicator into the live panel"
```

---

### Task 4: Build the hosts, deploy, accept

**Files:** none changed unless a check fails.

- [ ] **Step 1: Build both Pantheon hosts and run the flake check**

```bash
just build raider
just build blackbird
nix build .#checks.x86_64-linux.pantheon-gamemode-test .#checks.x86_64-linux.pantheon-dock-test -L
```

Expected: all succeed. (The dock test is rerun because both tests share the Pantheon session setup.)

- [ ] **Step 2: Push, then ask the user before deploying**

```bash
git push -u origin master
```

Ask the user whether to deploy raider now (`just deploy raider`) or leave it for the next tier-1 deploy. The new plugin loads only when Wingpanel restarts, i.e. on the next login, or immediately with `pkill -f '(^|/)io\.elementary\.wingpanel$'` (gala respawns it with the deployed indicators).

- [ ] **Step 3: Acceptance with a real Steam game (user-run, after deploy)**

Ask the user to launch a Steam game and confirm:
1. the controller icon appears within about 2 s (gamemode-steam-watch polls every 2 s);
2. the popover shows the game's Steam name, not `reaper`;
3. the icon disappears within about 5 s of quitting.

Cross-check from a shell: `journalctl --user -b -t io.elementary.wingpanel | grep -E 'GameMode|Game Mode games'`.
