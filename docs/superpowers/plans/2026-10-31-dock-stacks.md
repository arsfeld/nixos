# Dock Stacks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add macOS-style folder stacks (Downloads as a fan, Applications as a grid) to Pantheon's `elementary-dock`, configured from Nix.

**Architecture:** The new Vala sources live in this repo under
`modules/constellation/pantheon-dock-stacks/Stacks/` and are copied into the dock's source
tree at `src/Stacks/` in `postPatch`. A small `hooks.patch` wires them in: a schema key,
two lines in `src/meson.build`, and the stack group in `ItemManager.vala`. A NixOS module
`modules/constellation/pantheon-dock.nix` overlays `pantheon.elementary-dock` and writes
`io.elementary.dock stacks` as a system dconf default.

**Tech Stack:** Vala, GTK 4, GIO, Granite 7, libadwaita, meson; Nix (overlay with `overrideScope`/`overrideAttrs`, `programs.dconf`, `lib.gvariant`), NixOS VM tests.

Spec: `docs/superpowers/specs/2026-10-31-dock-stacks-design.md`.

## Global Constraints

- Base: `pantheon.elementary-dock` 8.3.3 (`https://github.com/elementary/dock/archive/8.3.3.tar.gz`). The patch must apply to exactly this source.
- gsettings key: `io.elementary.dock stacks`, type `a(ssss)`, default `[]`; tuple order `(source, view, sort, display)`.
- Allowed values: `source` = absolute path, `~/…`, or `applications`; `view` = `fan` | `grid`; `sort` = `date-added` | `name`; `display` = `stack` | `folder`.
- An invalid stack logs exactly `Ignoring stack <source>: <reason>` with `warning ()` and is skipped. The dock never fails because of bad config.
- The fan shows at most 10 entries, newest nearest the dock.
- Hidden files and in-progress downloads (`*.part`, `*.crdownload`, `*.download`) never appear.
- The Nix option is `constellation.desktop.pantheon.dockStacks`. Its effects are gated on `services.desktopManager.pantheon.enable`, so the module is self-contained and a VM test can import it alone.
- Commit straight to master. Conventional commits, scope `modules` (shared module) or `raider`/`blackbird`. Never mention Claude.
- **New files are invisible to `nix build` until `git add`ed.** Run `git add -N <path>` before building.
- Run `just fmt` (alejandra) before committing any `.nix` change.

## File Structure

```
modules/constellation/pantheon-dock.nix                 option, overlay, dconf default
modules/constellation/pantheon-dock-stacks/
  hooks.patch                                           schema key, meson hook, ItemManager hook
  Stacks/meson.build                                    stacks_sources + unit-test executable
  Stacks/StackConfig.vala                               parse/validate one (ssss) tuple; parse_all
  Stacks/StackEntry.vala                                one file or app: name, icon, sort key, launch, drag
  Stacks/StackSource.vala                               live, sorted ListModel of StackEntry for a config
  Stacks/StackStore.vala                                gsettings `stacks` -> ListModel of StackConfig
  Stacks/StackStyle.vala                                CSS for the fan, loaded once
  Stacks/StackItem.vala                                 the dock item (preview icon + popover)
  Stacks/GridPopover.vala                               grid view
  Stacks/FanLayout.vala                                 arc layout widget
  Stacks/FanPopover.vala                                fan view
  Stacks/tests/StackTests.vala                          GLib.Test unit tests (no display needed)
tests/pantheon-dock-stacks-test.nix                     NixOS VM test
flake-modules/checks.nix                                registers the VM test
hosts/raider/configuration.nix, hosts/blackbird/configuration.nix   declare the two stacks
```

haumea loads only `.nix` files from `modules/`, so the `.vala`, `meson.build` and `.patch` files
are ignored. `modules/constellation/certs/*.pem` is the precedent. The source directory is
named `pantheon-dock-stacks/` rather than `pantheon-dock/` because a directory and a `.nix`
file with the same stem would collide in haumea's attrset.

## Development loop (used by every task)

Build only the dock, which also runs its unit tests (`doCheck = true`):

```bash
cd /home/arosenfeld/Code/nixos
git add -N modules/constellation/pantheon-dock-stacks modules/constellation/pantheon-dock.nix
nix build --no-link -L .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock 2>&1 | tail -n 60
```

To regenerate `hooks.patch` after changing upstream files:

```bash
W=/tmp/claude-1000/-home-arosenfeld-Code-nixos/2c789421-cf93-4ac9-91a1-766cac869527/scratchpad/dock-src
rm -rf "$W" && mkdir -p "$W"
cp -r "$(nix build --no-link --print-out-paths --impure --expr '(builtins.getFlake "/home/arosenfeld/Code/nixos").inputs.nixpkgs.legacyPackages.x86_64-linux.pantheon.elementary-dock.src')"/. "$W"
chmod -R u+w "$W" && cd "$W" && git init -q && git add -A && git commit -qm base
# apply the current patch (if one exists), edit, then:
git -C "$W" apply /home/arosenfeld/Code/nixos/modules/constellation/pantheon-dock-stacks/hooks.patch || true
# ... edit files in $W ...
git -C "$W" diff > /home/arosenfeld/Code/nixos/modules/constellation/pantheon-dock-stacks/hooks.patch
```

---

### Task 1: Nix module, schema hook and `StackConfig`

**Files:**
- Create: `modules/constellation/pantheon-dock.nix`
- Create: `modules/constellation/pantheon-dock-stacks/hooks.patch`
- Create: `modules/constellation/pantheon-dock-stacks/Stacks/meson.build`
- Create: `modules/constellation/pantheon-dock-stacks/Stacks/StackConfig.vala`
- Create: `modules/constellation/pantheon-dock-stacks/Stacks/tests/StackTests.vala`
- Modify: `hosts/raider/configuration.nix`, `hosts/blackbird/configuration.nix` (the `constellation.desktop` block)

**Interfaces:**
- Produces (Vala): `Dock.StackConfig` with `enum View { FAN, GRID }`, `enum Sort { DATE_ADDED, NAME }`, `enum Display { STACK, FOLDER }`, `const string APPLICATIONS = "applications"`, properties `string source` (resolved absolute path or `"applications"`), `View view`, `Sort sort`, `Display display`, `bool is_applications`; `static StackConfig parse (string source, string view, string sort, string display) throws StackConfigError`; `static GenericArray<StackConfig> parse_all (Variant stacks)`. `errordomain Dock.StackConfigError { INVALID }`.
- Produces (meson): variables `stacks_core_sources` (no widgets, used by the test) and `stacks_sources` (everything, linked into the dock).
- Produces (Nix): option `constellation.desktop.pantheon.dockStacks : listOf {source; view; sort; display}`.

- [ ] **Step 1: Write the failing unit test**

`modules/constellation/pantheon-dock-stacks/Stacks/tests/StackTests.vala`:

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Unit tests for the stack config and data layer. Nothing here needs a display.
 */

using Dock;

void test_parse_expands_home () {
    try {
        var config = StackConfig.parse ("~/Downloads", "fan", "date-added", "stack");
        assert_cmpstr (config.source, EQ, Path.build_filename (Environment.get_home_dir (), "Downloads"));
        assert_true (config.view == StackConfig.View.FAN);
        assert_true (config.sort == StackConfig.Sort.DATE_ADDED);
        assert_true (config.display == StackConfig.Display.STACK);
        assert_false (config.is_applications);
    } catch (StackConfigError e) {
        error ("unexpected error: %s", e.message);
    }
}

void test_parse_applications () {
    try {
        var config = StackConfig.parse ("applications", "grid", "name", "folder");
        assert_cmpstr (config.source, EQ, "applications");
        assert_true (config.is_applications);
        assert_true (config.view == StackConfig.View.GRID);
        assert_true (config.sort == StackConfig.Sort.NAME);
        assert_true (config.display == StackConfig.Display.FOLDER);
    } catch (StackConfigError e) {
        error ("unexpected error: %s", e.message);
    }
}

void assert_rejected (string source, string view, string sort, string display) {
    try {
        StackConfig.parse (source, view, sort, display);
        error ("accepted (%s, %s, %s, %s)", source, view, sort, display);
    } catch (StackConfigError e) {
        // expected
    }
}

void test_parse_rejects_invalid () {
    assert_rejected ("Downloads", "fan", "name", "stack");          // relative path
    assert_rejected ("/tmp", "spiral", "name", "stack");            // unknown view
    assert_rejected ("/tmp", "fan", "size", "stack");               // unknown sort
    assert_rejected ("/tmp", "fan", "name", "pile");                // unknown display
}

void test_parse_all_skips_invalid () {
    var stacks = new Variant.parsed ("[('/tmp', 'fan', 'name', 'stack'), ('/tmp', 'spiral', 'name', 'stack'), ('applications', 'grid', 'name', 'stack')]");
    // The dock sets no G_LOG_DOMAIN, so warnings carry a null domain.
    Test.expect_message (null, LogLevelFlags.LEVEL_WARNING, "Ignoring stack /tmp: *");
    var configs = StackConfig.parse_all (stacks);
    Test.assert_expected_messages ();
    assert_cmpuint (configs.length, EQ, 2);
    assert_cmpstr (configs[0].source, EQ, "/tmp");
    assert_true (configs[1].is_applications);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/stack-config/expands-home", test_parse_expands_home);
    Test.add_func ("/stack-config/applications", test_parse_applications);
    Test.add_func ("/stack-config/rejects-invalid", test_parse_rejects_invalid);
    Test.add_func ("/stack-config/parse-all-skips-invalid", test_parse_all_skips_invalid);
    return Test.run ();
}
```

`modules/constellation/pantheon-dock-stacks/Stacks/meson.build`:

```meson
# Copied into the dock's src/Stacks/ by modules/constellation/pantheon-dock.nix.
# Core files must not touch widgets that need a display: the unit test links
# only them and runs inside the Nix build sandbox.
stacks_core_sources = files(
    'StackConfig.vala',
)

stacks_sources = stacks_core_sources + files(
)

stacks_test = executable(
    'stacks-test',
    stacks_core_sources + files('tests' / 'StackTests.vala'),
    dependencies: dependencies,
)

test('stacks', stacks_test)
```

(`files()` with no arguments is valid meson and yields an empty list. Later tasks add files to it.)

- [ ] **Step 2: Write the hooks patch (schema key + meson hook only)**

Use the "regenerate `hooks.patch`" procedure in the Development loop section. In `$W`:

1. `data/dock.gschema.xml`: insert this after the `launchers` `</key>` inside the `io.elementary.dock` schema:

```xml
    <key type="a(ssss)" name="stacks">
      <default>[]</default>
      <summary>Folder stacks shown after the launchers</summary>
      <description>Each entry is (source, view, sort, display): source is an absolute path, a path starting with ~/, or 'applications'; view is 'fan' or 'grid'; sort is 'date-added' or 'name'; display is 'stack' or 'folder'.</description>
    </key>
```

2. `src/meson.build`: insert `subdir('Stacks')` as the first line, and directly after the closing `]` of the `sources = [ … ]` list add:

```meson
sources += stacks_sources
```

Then `git -C "$W" diff > …/hooks.patch`.

- [ ] **Step 3: Write the Nix module**

`modules/constellation/pantheon-dock.nix`:

```nix
# Folder stacks for Pantheon's dock (elementary-dock), modelled on macOS dock
# stacks: Downloads fanned out newest-first, Applications as a grid.
#
# elementary-dock has no applet API, so this carries a local patch. The Vala
# sources live in ./pantheon-dock-stacks/Stacks and are copied into the dock's
# src/Stacks; hooks.patch only adds the gsettings key, the meson hook and the
# stack group in ItemManager. A nixpkgs bump of elementary-dock that breaks
# hooks.patch fails the build, and the patch is rebased on the new source.
#
# Gated on services.desktopManager.pantheon.enable rather than
# constellation.desktop.variant, so a VM test can import this module alone.
# Design: docs/superpowers/specs/2026-10-31-dock-stacks-design.md
{
  config,
  lib,
  ...
}: let
  cfg = config.constellation.desktop.pantheon;
  stacksDir = ./pantheon-dock-stacks;
  inherit (lib.gvariant) mkArray mkTuple;
in {
  options.constellation.desktop.pantheon.dockStacks = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        source = lib.mkOption {
          type = lib.types.str;
          description = "Absolute path, a path starting with ~/, or \"applications\".";
        };
        view = lib.mkOption {
          type = lib.types.enum ["fan" "grid"];
          default = "grid";
        };
        sort = lib.mkOption {
          type = lib.types.enum ["date-added" "name"];
          default = "name";
        };
        display = lib.mkOption {
          type = lib.types.enum ["stack" "folder"];
          default = "stack";
        };
      };
    });
    default = [];
    description = "Folder stacks shown on the elementary dock, after the launchers.";
  };

  config = lib.mkIf config.services.desktopManager.pantheon.enable {
    nixpkgs.overlays = [
      (final: prev: {
        pantheon = prev.pantheon.overrideScope (pfinal: pprev: {
          elementary-dock = pprev.elementary-dock.overrideAttrs (old: {
            patches = (old.patches or []) ++ ["${stacksDir}/hooks.patch"];
            postPatch =
              (old.postPatch or "")
              + ''
                cp -r ${stacksDir}/Stacks src/Stacks
                chmod -R u+w src/Stacks
              '';
            doCheck = true;
          });
        });
      })
    ];

    programs.dconf.profiles.user.databases = lib.mkIf (cfg.dockStacks != []) [
      {
        settings."io/elementary/dock".stacks = mkArray (map (s: mkTuple [s.source s.view s.sort s.display]) cfg.dockStacks);
      }
    ];
  };
}
```

Add to both hosts' `constellation.desktop` attrset (in `hosts/raider/configuration.nix` and `hosts/blackbird/configuration.nix`), next to `variant = "pantheon";`:

```nix
      pantheon.dockStacks = [
        {
          source = "~/Downloads";
          view = "fan";
          sort = "date-added";
        }
        {source = "applications";}
      ];
```

- [ ] **Step 4: Write a deliberately incomplete `StackConfig.vala` and confirm the test fails**

`modules/constellation/pantheon-dock-stacks/Stacks/StackConfig.vala` first contains only the class shell (no `parse_all`) so the build fails at compile time:

```vala
public class Dock.StackConfig : Object {
}
```

Run the dock build from the Development loop.
Expected: FAIL, valac errors such as `The name 'parse' does not exist in the context of 'Dock.StackConfig'`.

- [ ] **Step 5: Implement `StackConfig.vala`**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * One entry of the io.elementary.dock `stacks` key, validated.
 */

namespace Dock {
    public errordomain StackConfigError {
        INVALID
    }
}

public class Dock.StackConfig : Object {
    public enum View { FAN, GRID }
    public enum Sort { DATE_ADDED, NAME }
    public enum Display { STACK, FOLDER }

    public const string APPLICATIONS = "applications";

    /* An absolute path, or APPLICATIONS. */
    public string source { get; construct; }
    public View view { get; construct; }
    public Sort sort { get; construct; }
    public Display display { get; construct; }

    public bool is_applications { get { return source == APPLICATIONS; } }

    public StackConfig (string source, View view, Sort sort, Display display) {
        Object (source: source, view: view, sort: sort, display: display);
    }

    public static StackConfig parse (string source, string view, string sort, string display) throws StackConfigError {
        string resolved;
        if (source == APPLICATIONS || Path.is_absolute (source)) {
            resolved = source;
        } else if (source.has_prefix ("~/")) {
            resolved = Path.build_filename (Environment.get_home_dir (), source.substring (2));
        } else {
            throw new StackConfigError.INVALID ("source must be an absolute path, ~/…, or '%s'", APPLICATIONS);
        }

        View parsed_view;
        switch (view) {
            case "fan": parsed_view = FAN; break;
            case "grid": parsed_view = GRID; break;
            default: throw new StackConfigError.INVALID ("unknown view '%s'", view);
        }

        Sort parsed_sort;
        switch (sort) {
            case "date-added": parsed_sort = DATE_ADDED; break;
            case "name": parsed_sort = NAME; break;
            default: throw new StackConfigError.INVALID ("unknown sort '%s'", sort);
        }

        Display parsed_display;
        switch (display) {
            case "stack": parsed_display = STACK; break;
            case "folder": parsed_display = FOLDER; break;
            default: throw new StackConfigError.INVALID ("unknown display '%s'", display);
        }

        return new StackConfig (resolved, parsed_view, parsed_sort, parsed_display);
    }

    /* Parses an a(ssss) value, logging and skipping invalid entries. */
    public static GenericArray<StackConfig> parse_all (Variant stacks) {
        var result = new GenericArray<StackConfig> ();
        for (size_t i = 0; i < stacks.n_children (); i++) {
            var entry = stacks.get_child_value (i);
            var source = entry.get_child_value (0).get_string ();
            try {
                result.add (parse (
                    source,
                    entry.get_child_value (1).get_string (),
                    entry.get_child_value (2).get_string (),
                    entry.get_child_value (3).get_string ()
                ));
            } catch (StackConfigError e) {
                warning ("Ignoring stack %s: %s", source, e.message);
            }
        }
        return result;
    }
}
```

- [ ] **Step 6: Build and run the tests**

Run the dock build from the Development loop.
Expected: PASS; the log shows `1/1 stacks OK` from `meson test`. If `Test.expect_message` does not match because the build sets a log domain, read the domain off the failure message and use it in place of `null`.

Then check that both hosts evaluate and the key lands in dconf:

```bash
nix eval .#nixosConfigurations.raider.config.constellation.desktop.pantheon.dockStacks --json
nix eval .#nixosConfigurations.blackbird.config.constellation.desktop.pantheon.dockStacks --json
```
Expected: both print the two stacks, with defaults filled in (`"display":"stack"` etc.).

- [ ] **Step 7: Format and commit**

```bash
just fmt
git add modules/constellation/pantheon-dock.nix modules/constellation/pantheon-dock-stacks hosts/raider/configuration.nix hosts/blackbird/configuration.nix
git commit -m "feat(modules): add a stacks config key to the elementary dock"
```

---

### Task 2: `StackEntry` and `StackSource` (the live data layer)

**Files:**
- Create: `modules/constellation/pantheon-dock-stacks/Stacks/StackEntry.vala`
- Create: `modules/constellation/pantheon-dock-stacks/Stacks/StackSource.vala`
- Modify: `modules/constellation/pantheon-dock-stacks/Stacks/meson.build` (add both to `stacks_core_sources`)
- Modify: `modules/constellation/pantheon-dock-stacks/Stacks/tests/StackTests.vala`

**Interfaces:**
- Consumes: `Dock.StackConfig` (Task 1).
- Produces: `Dock.StackEntry : Object` with properties `string name`, `Icon icon`, `File? file`, `AppInfo? app`, `int64 added_usec`; `static StackEntry from_file_info (File file, FileInfo info)`; `static StackEntry from_app (AppInfo app)`; `void launch ()`; `delegate StackEntry? Getter ()`; `static void attach_drag_source (Gtk.Widget widget, owned Getter get_entry)`.
- Produces: `Dock.StackSource : Object` with `StackConfig config`, `ListModel entries` (of `StackEntry`, sorted per `config.sort`), `bool missing`, `signal void loaded ()` (emitted after every reload), `static bool is_shown_name (string name)`, `void open_location ()`.

- [ ] **Step 1: Write the failing tests**

Append these functions to `StackTests.vala` above `main`, and register them in `main`. The `Environment.set_variable` lines must run before anything touches `AppInfo`, so they go at the top of `main`.

```vala
string[] entry_names (StackSource source) {
    string[] names = {};
    for (uint i = 0; i < source.entries.get_n_items (); i++) {
        names += ((StackEntry) source.entries.get_item (i)).name;
    }
    return names;
}

void wait_for_load (StackSource source) {
    var loop = new MainLoop ();
    var handler = source.loaded.connect (() => loop.quit ());
    var timeout_id = Timeout.add_seconds (5, () => {
        error ("timed out waiting for StackSource.loaded");
    });
    loop.run ();
    Source.remove (timeout_id);
    source.disconnect (handler);
}

string make_folder () {
    try {
        var dir = DirUtils.make_tmp ("stacks-XXXXXX");
        // alpha.pdf is created first, so it is older but sorts first by name.
        FileUtils.set_contents (Path.build_filename (dir, "alpha.pdf"), "x");
        Thread.usleep (50000);
        FileUtils.set_contents (Path.build_filename (dir, "zeta.zip"), "x");
        FileUtils.set_contents (Path.build_filename (dir, ".hidden"), "x");
        FileUtils.set_contents (Path.build_filename (dir, "big.iso.part"), "x");
        FileUtils.set_contents (Path.build_filename (dir, "video.mp4.crdownload"), "x");
        FileUtils.set_contents (Path.build_filename (dir, "safari.download"), "x");
        return dir;
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}

void test_shown_names () {
    assert_true (StackSource.is_shown_name ("report.pdf"));
    assert_false (StackSource.is_shown_name (".hidden"));
    assert_false (StackSource.is_shown_name ("a.part"));
    assert_false (StackSource.is_shown_name ("a.crdownload"));
    assert_false (StackSource.is_shown_name ("a.download"));
}

void test_folder_date_added () {
    var source = new StackSource (new StackConfig (make_folder (), FAN, DATE_ADDED, STACK));
    wait_for_load (source);
    assert_false (source.missing);
    assert_true (strv_equal (entry_names (source), { "zeta.zip", "alpha.pdf" }));
}

void test_folder_name () {
    var source = new StackSource (new StackConfig (make_folder (), GRID, NAME, STACK));
    wait_for_load (source);
    assert_true (strv_equal (entry_names (source), { "alpha.pdf", "zeta.zip" }));
}

void test_folder_live_update () {
    var dir = make_folder ();
    var source = new StackSource (new StackConfig (dir, FAN, DATE_ADDED, STACK));
    wait_for_load (source);
    Thread.usleep (50000);
    try {
        FileUtils.set_contents (Path.build_filename (dir, "newest.txt"), "x");
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
    wait_for_load (source);
    assert_true (strv_equal (entry_names (source), { "newest.txt", "zeta.zip", "alpha.pdf" }));
}

void test_folder_missing () {
    var source = new StackSource (new StackConfig ("/nonexistent/stacks-test", FAN, DATE_ADDED, STACK));
    wait_for_load (source);
    assert_true (source.missing);
    assert_cmpuint (source.entries.get_n_items (), EQ, 0);
}

void test_applications () {
    var source = new StackSource (new StackConfig (StackConfig.APPLICATIONS, GRID, NAME, STACK));
    wait_for_load (source);
    // Case-insensitive A–Z; the NoDisplay entry is left out.
    assert_true (strv_equal (entry_names (source), { "alpha", "Beta" }));
}

void write_desktop_files (string data_dir) {
    var apps = Path.build_filename (data_dir, "applications");
    DirUtils.create_with_parents (apps, 0755);
    try {
        FileUtils.set_contents (Path.build_filename (apps, "b.desktop"), "[Desktop Entry]\nType=Application\nName=Beta\nExec=true\n");
        FileUtils.set_contents (Path.build_filename (apps, "a.desktop"), "[Desktop Entry]\nType=Application\nName=alpha\nExec=true\n");
        FileUtils.set_contents (Path.build_filename (apps, "hidden.desktop"), "[Desktop Entry]\nType=Application\nName=Hidden\nExec=true\nNoDisplay=true\n");
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}
```

At the top of `main`, before `Test.init`:

```vala
    // AppInfo reads these once, on first use: point it at fixture apps only.
    try {
        var data_dir = DirUtils.make_tmp ("stacks-apps-XXXXXX");
        write_desktop_files (data_dir);
        Environment.set_variable ("XDG_DATA_DIRS", data_dir, true);
        Environment.set_variable ("XDG_DATA_HOME", DirUtils.make_tmp ("stacks-home-XXXXXX"), true);
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
```

Register them:

```vala
    Test.add_func ("/stack-source/shown-names", test_shown_names);
    Test.add_func ("/stack-source/folder-date-added", test_folder_date_added);
    Test.add_func ("/stack-source/folder-name", test_folder_name);
    Test.add_func ("/stack-source/folder-live-update", test_folder_live_update);
    Test.add_func ("/stack-source/folder-missing", test_folder_missing);
    Test.add_func ("/stack-source/applications", test_applications);
```

`strv_equal` is GLib's `g_strv_equal` (GLib ≥ 2.60), bound in Vala as `GLib.strv_equal`.
If the binding is missing in this valac, write a 6-line local helper that compares length
and elements.

Add `'StackEntry.vala', 'StackSource.vala',` to `stacks_core_sources` in `Stacks/meson.build`.

- [ ] **Step 2: Run the build to verify it fails**

Run the dock build from the Development loop.
Expected: FAIL, because valac cannot find `StackSource`/`StackEntry` (the files do not exist yet: create them empty first so meson does not fail on missing files).

- [ ] **Step 3: Implement `StackEntry.vala`**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * One thing in a stack: a file in a folder, or an installed app.
 */

public class Dock.StackEntry : Object {
    public delegate StackEntry? Getter ();

    public string name { get; construct; }
    public Icon icon { get; construct; }
    public File? file { get; construct; }
    public AppInfo? app { get; construct; }
    /* Sort key for date-added: creation time, or modification time where the filesystem has none. */
    public int64 added_usec { get; construct; }

    public StackEntry (string name, Icon icon, File? file, AppInfo? app, int64 added_usec) {
        Object (name: name, icon: icon, file: file, app: app, added_usec: added_usec);
    }

    public static StackEntry from_file_info (File file, FileInfo info) {
        Icon icon = info.get_icon () ?? new ThemedIcon ("text-x-generic");
        var thumbnail = info.get_attribute_byte_string (FileAttribute.THUMBNAIL_PATH);
        if (thumbnail != null) {
            icon = new FileIcon (File.new_for_path (thumbnail));
        }

        int64 added;
        if (info.has_attribute (FileAttribute.TIME_CREATED)) {
            added = (int64) info.get_attribute_uint64 (FileAttribute.TIME_CREATED) * 1000000
                + info.get_attribute_uint32 (FileAttribute.TIME_CREATED_USEC);
        } else {
            added = (int64) info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED) * 1000000
                + info.get_attribute_uint32 (FileAttribute.TIME_MODIFIED_USEC);
        }

        return new StackEntry (info.get_display_name (), icon, file, null, added);
    }

    public static StackEntry from_app (AppInfo app) {
        return new StackEntry (
            app.get_display_name (),
            app.get_icon () ?? new ThemedIcon ("application-default-icon"),
            null,
            app,
            0
        );
    }

    public void launch () {
        var context = Gdk.Display.get_default ().get_app_launch_context ();
        try {
            if (app != null) {
                app.launch (null, context);
            } else {
                AppInfo.launch_default_for_uri (file.get_uri (), context);
            }
        } catch (Error e) {
            critical ("Failed to open %s: %s", name, e.message);
        }
    }

    /*
     * Lets a file entry be dragged out of a popover (into a browser upload, a
     * mail, Files). get_entry is called at drag time, so recycled grid cells
     * always drag the entry they currently show.
     */
    public static void attach_drag_source (Gtk.Widget widget, owned Getter get_entry) {
        var drag_source = new Gtk.DragSource () {
            actions = COPY
        };
        drag_source.prepare.connect ((x, y) => {
            var entry = get_entry ();
            if (entry == null || entry.file == null) {
                return null;
            }

            var value = Value (typeof (File));
            value.set_object (entry.file);
            return new Gdk.ContentProvider.for_value (value);
        });
        widget.add_controller (drag_source);
    }
}
```

- [ ] **Step 4: Implement `StackSource.vala`**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The live, sorted contents of one stack: a folder watched with a
 * FileMonitor, or every app that should be shown.
 */

public class Dock.StackSource : Object {
    private const string FILE_ATTRIBUTES = "standard::name,standard::display-name,standard::icon," +
        "standard::is-hidden,standard::is-backup,time::created,time::created-usec," +
        "time::modified,time::modified-usec,thumbnail::path";
    // Downloads arrive as bursts of events (create, write, rename); reload once per burst.
    private const uint RELOAD_DELAY_MS = 200;

    public signal void loaded ();

    public StackConfig config { get; construct; }
    public ListModel entries { get { return store; } }
    public bool missing { get; private set; default = false; }

    private ListStore store;
    private FileMonitor? monitor;
    private AppInfoMonitor? app_monitor;
    private Cancellable? cancellable;
    private uint reload_id = 0;

    public StackSource (StackConfig config) {
        Object (config: config);
    }

    construct {
        store = new ListStore (typeof (StackEntry));

        if (config.is_applications) {
            app_monitor = AppInfoMonitor.get ();
            app_monitor.changed.connect (queue_reload);
        } else {
            try {
                monitor = File.new_for_path (config.source).monitor_directory (WATCH_MOVES, null);
                monitor.changed.connect ((file, other, event) => queue_reload ());
            } catch (Error e) {
                debug ("Not watching %s: %s", config.source, e.message);
            }
        }

        // Deferred so callers can connect to `loaded` before the first load.
        queue_reload ();
    }

    public static bool is_shown_name (string name) {
        return !name.has_prefix (".")
            && !name.has_suffix (".part")
            && !name.has_suffix (".crdownload")
            && !name.has_suffix (".download");
    }

    public void open_location () {
        var context = Gdk.Display.get_default ().get_app_launch_context ();
        try {
            AppInfo.launch_default_for_uri (File.new_for_path (config.source).get_uri (), context);
        } catch (Error e) {
            critical ("Failed to open %s: %s", config.source, e.message);
        }
    }

    private void queue_reload () {
        if (reload_id != 0) {
            Source.remove (reload_id);
        }

        reload_id = Timeout.add_once (RELOAD_DELAY_MS, () => {
            reload_id = 0;
            reload.begin ();
        });
    }

    private async void reload () {
        if (cancellable != null) {
            cancellable.cancel ();
        }
        var current = new Cancellable ();
        cancellable = current;

        GenericArray<StackEntry> loaded_entries;
        if (config.is_applications) {
            loaded_entries = load_applications ();
        } else {
            loaded_entries = yield load_folder (current);
        }

        if (current.is_cancelled ()) {
            return;
        }

        loaded_entries.sort (config.sort == NAME ? (CompareFunc<StackEntry>) compare_name : (CompareFunc<StackEntry>) compare_newest_first);

        Object[] items = {};
        foreach (var entry in loaded_entries) {
            items += entry;
        }
        store.splice (0, store.get_n_items (), items);

        loaded ();
    }

    private async GenericArray<StackEntry> load_folder (Cancellable cancellable) {
        var result = new GenericArray<StackEntry> ();
        var dir = File.new_for_path (config.source);

        try {
            var enumerator = yield dir.enumerate_children_async (FILE_ATTRIBUTES, NONE, Priority.DEFAULT, cancellable);
            missing = false;

            List<FileInfo> infos;
            while ((infos = yield enumerator.next_files_async (64, Priority.DEFAULT, cancellable)) != null) {
                foreach (var info in infos) {
                    if (info.get_is_hidden () || info.get_is_backup () || !is_shown_name (info.get_name ())) {
                        continue;
                    }
                    result.add (StackEntry.from_file_info (dir.get_child (info.get_name ()), info));
                }
            }
        } catch (IOError.CANCELLED e) {
            // A newer reload took over.
        } catch (IOError.NOT_FOUND e) {
            missing = true;
        } catch (Error e) {
            missing = true;
            warning ("Failed to read %s: %s", config.source, e.message);
        }

        return result;
    }

    private GenericArray<StackEntry> load_applications () {
        var result = new GenericArray<StackEntry> ();
        foreach (var app in AppInfo.get_all ()) {
            if (app.should_show ()) {
                result.add (StackEntry.from_app (app));
            }
        }
        return result;
    }

    private static int compare_name (StackEntry a, StackEntry b) {
        return a.name.casefold ().collate (b.name.casefold ());
    }

    private static int compare_newest_first (StackEntry a, StackEntry b) {
        if (a.added_usec != b.added_usec) {
            return a.added_usec > b.added_usec ? -1 : 1;
        }
        return compare_name (a, b);
    }
}
```

If valac rejects the `(CompareFunc<StackEntry>)` casts, replace the line with an `if`/`else`
that calls `loaded_entries.sort (compare_name)` or `loaded_entries.sort (compare_newest_first)`.

- [ ] **Step 5: Build and run the tests**

Run the dock build from the Development loop.
Expected: PASS, `1/1 stacks OK`, with all ten test paths reported. If
`folder-live-update` times out, the sandbox has no inotify. Confirm that with
`nix build … --option sandbox relaxed` before you blame the code, and report it rather
than deleting the test.

- [ ] **Step 6: Commit**

```bash
git add modules/constellation/pantheon-dock-stacks
git commit -m "feat(modules): load and watch stack contents for the elementary dock"
```

---

### Task 3: `StackItem`, the grid view, and wiring into the dock

After this task the dock shows both stacks. Both open as a grid, including Downloads,
until Task 4 adds the fan.

**Files:**
- Create: `modules/constellation/pantheon-dock-stacks/Stacks/StackStore.vala`
- Create: `modules/constellation/pantheon-dock-stacks/Stacks/StackItem.vala`
- Create: `modules/constellation/pantheon-dock-stacks/Stacks/GridPopover.vala`
- Modify: `modules/constellation/pantheon-dock-stacks/Stacks/meson.build` (UI files into `stacks_sources`)
- Modify: `modules/constellation/pantheon-dock-stacks/hooks.patch` (add the `ItemManager.vala` hook)

**Interfaces:**
- Consumes: `StackConfig`, `StackConfig.parse_all`, `StackSource`, `StackEntry` (Tasks 1–2). Dock classes: `Dock.BaseIconGroup` (abstract, construct property `ListModel icons`, sets `child` to a 2×2 icon `FlowBox`), `Dock.ContainerItem.child`, `Dock.BaseItem` (`protected Gtk.Popover popover_menu`, which **must be non-null** because `BaseItem` reads `popover_menu.visible` when showing tooltips; `protected Gtk.GestureClick gesture_click`; `string tooltip_text`; `int icon_size`; construct property `Group group`, with `Group.NONE` disabling drag-reorder), and `Dock.ItemGroup (ListModel items, CreateBaseItemFunc create_item_func)`, whose delegate is `has_target = false`, so the lambda must not capture anything.
- Produces: `Dock.StackStore : Object` with `ListModel configs` (of `StackConfig`, rebuilt on `changed::stacks`); `Dock.StackItem : BaseIconGroup` with `StackItem (StackConfig config)`, properties `config`, `source`; `Dock.GridPopover : Gtk.Popover` with `GridPopover (StackSource source)`.

- [ ] **Step 1: Write `StackStore.vala`**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The io.elementary.dock `stacks` key as a list model of StackConfig.
 */

public class Dock.StackStore : Object {
    public ListModel configs { get { return store; } }

    private Settings settings;
    private ListStore store;

    construct {
        store = new ListStore (typeof (StackConfig));
        settings = new Settings ("io.elementary.dock");
        settings.changed["stacks"].connect (load);
        load ();
    }

    private void load () {
        Object[] items = {};
        foreach (var config in StackConfig.parse_all (settings.get_value ("stacks"))) {
            items += config;
        }
        store.splice (0, store.get_n_items (), items);
    }
}
```

- [ ] **Step 2: Write `GridPopover.vala`**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * A stack opened as a scrollable grid, like a macOS Grid stack.
 */

public class Dock.GridPopover : Gtk.Popover {
    private const int COLUMNS = 6;
    private const int VISIBLE_ROWS = 5;
    private const int CELL_WIDTH = 96;
    private const int CELL_HEIGHT = 100;
    private const int ICON_SIZE = 48;

    public StackSource source { get; construct; }

    private Gtk.Stack content;

    public GridPopover (StackSource source) {
        Object (source: source, position: Gtk.PositionType.TOP);
    }

    construct {
        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect ((obj) => {
            var list_item = (Gtk.ListItem) obj;

            var box = new Gtk.Box (VERTICAL, 6) {
                width_request = CELL_WIDTH,
                margin_top = 6,
                margin_bottom = 6
            };
            box.append (new Gtk.Image () { pixel_size = ICON_SIZE });
            box.append (new Gtk.Label (null) {
                ellipsize = END,
                max_width_chars = 12,
                justify = CENTER
            });

            StackEntry.attach_drag_source (box, () => (StackEntry?) list_item.item);
            list_item.child = box;
        });
        factory.bind.connect ((obj) => {
            var list_item = (Gtk.ListItem) obj;
            var entry = (StackEntry) list_item.item;
            var box = (Gtk.Box) list_item.child;
            ((Gtk.Image) box.get_first_child ()).gicon = entry.icon;
            ((Gtk.Label) box.get_last_child ()).label = entry.name;
        });

        var grid = new Gtk.GridView (new Gtk.NoSelection (source.entries), factory) {
            min_columns = COLUMNS,
            max_columns = COLUMNS,
            single_click_activate = true
        };
        grid.activate.connect ((position) => {
            var entry = (StackEntry) source.entries.get_item (position);
            popdown ();
            entry.launch ();
        });

        var scrolled = new Gtk.ScrolledWindow () {
            child = grid,
            hscrollbar_policy = NEVER,
            width_request = CELL_WIDTH * COLUMNS,
            max_content_height = CELL_HEIGHT * VISIBLE_ROWS,
            propagate_natural_height = true
        };

        var message = new Gtk.Label (null) {
            margin_top = 24,
            margin_bottom = 24,
            margin_start = 24,
            margin_end = 24
        };
        message.add_css_class (Granite.STYLE_CLASS_DIM_LABEL);

        content = new Gtk.Stack ();
        content.add_named (scrolled, "grid");
        content.add_named (message, "message");
        child = content;

        // We need to set offset because dock window's height is 1px larger than its visible area
        set_offset (0, -1);

        source.notify["missing"].connect (() => update_message (message));
        source.entries.items_changed.connect (() => update_message (message));
        update_message (message);
    }

    private void update_message (Gtk.Label message) {
        if (source.missing) {
            message.label = _("Folder not found");
            content.visible_child_name = "message";
        } else if (source.entries.get_n_items () == 0) {
            message.label = _("No items");
            content.visible_child_name = "message";
        } else {
            content.visible_child_name = "grid";
        }
    }
}
```

- [ ] **Step 3: Write `StackItem.vala`**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * A folder stack on the dock: a live 2×2 preview of the newest entries (or a
 * plain folder icon), opening as a fan or a grid.
 */

public class Dock.StackItem : BaseIconGroup {
    public StackConfig config { get; construct; }
    public StackSource source { get; construct; }

    private Gtk.Widget preview;
    private Gtk.Image folder_image;

    public StackItem (StackConfig config) {
        var source = new StackSource (config);
        Object (
            config: config,
            source: source,
            icons: new Gtk.MapListModel (source.entries, (entry) => {
                return ((StackEntry) entry).icon;
            }),
            group: Group.NONE
        );
    }

    construct {
        // BaseIconGroup has already set child to its icon grid.
        preview = child;

        folder_image = new Gtk.Image.from_gicon (folder_icon ());
        bind_property ("icon-size", folder_image, "pixel-size", SYNC_CREATE);

        tooltip_text = config.is_applications ? _("Applications") : Path.get_basename (config.source);

        popover_menu = create_popover ();
        popover_menu.set_parent (this);

        gesture_click.released.connect (() => popover_menu.popup ());

        source.notify["missing"].connect (update_child);
        source.entries.items_changed.connect (update_child);
        update_child ();
    }

    ~StackItem () {
        popover_menu.unparent ();
        popover_menu.dispose ();
    }

    // Task 4 replaces this with a switch on config.view.
    private Gtk.Popover create_popover () {
        return new GridPopover (source);
    }

    private void update_child () {
        var empty = source.missing || source.entries.get_n_items () == 0;
        Gtk.Widget wanted = (config.display == FOLDER || empty) ? folder_image : preview;
        if (child != wanted) {
            child = wanted;
        }
        folder_image.opacity = source.missing ? 0.5 : 1.0;
    }

    private Icon folder_icon () {
        if (config.is_applications) {
            return new ThemedIcon ("applications-other");
        }
        if (config.source == Environment.get_user_special_dir (DOWNLOAD)) {
            return new ThemedIcon ("folder-download");
        }
        try {
            var info = File.new_for_path (config.source).query_info (FileAttribute.STANDARD_ICON, NONE);
            return info.get_icon () ?? new ThemedIcon ("folder");
        } catch (Error e) {
            return new ThemedIcon ("folder");
        }
    }
}
```

`Environment.get_user_special_dir (DOWNLOAD)` is `UserDirectory.DOWNLOAD`. If valac
needs the qualified form, write `UserDirectory.DOWNLOAD`.

Update `Stacks/meson.build`:

```meson
stacks_sources = stacks_core_sources + files(
    'GridPopover.vala',
    'StackItem.vala',
    'StackStore.vala',
)
```

- [ ] **Step 4: Hook the stack group into `ItemManager.vala`**

Use the regenerate procedure (apply the existing `hooks.patch` first). In `$W/src/ItemManager.vala`'s `construct`, after the `background_group` line, add:

```vala
        var stack_store = new StackStore ();
        var stack_group = new ItemGroup (stack_store.configs, (obj) => new StackItem ((StackConfig) obj));
```

and change

```vala
        append (app_group);
        append (background_group);
```

to

```vala
        append (app_group);
        append (stack_group);
        append (background_group);
```

`stack_store` must outlive `construct`, because its `changed::stacks` handler is what
reloads the stacks. Make it a private field: add `private StackStore stack_store;` next to
`dynamic_workspace_item`, and assign `stack_store = new StackStore ();` (no `var`).
Regenerate `hooks.patch`.

- [ ] **Step 5: Build**

Run the dock build from the Development loop.
Expected: PASS (compiles, unit tests still `OK`). Then build the whole host:

```bash
nix build --no-link .#nixosConfigurations.raider.config.system.build.toplevel
```

Expected: PASS.

- [ ] **Step 6: Smoke-test the patched dock on raider without deploying**

This is the user's live session. Replacing the dock process is harmless: gnome-session
restarts it if it exits.

```bash
DOCK=$(nix build --no-link --print-out-paths .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock)
gsettings set io.elementary.dock stacks "[('~/Downloads', 'grid', 'date-added', 'stack'), ('applications', 'grid', 'name', 'stack')]"
pkill -x io.elementary.dock; sleep 1
GSETTINGS_SCHEMA_DIR=$DOCK/share/gsettings-schemas/$(basename $DOCK)/glib-2.0/schemas setsid $DOCK/bin/io.elementary.dock >/tmp/claude-1000/-home-arosenfeld-Code-nixos/2c789421-cf93-4ac9-91a1-766cac869527/scratchpad/dock.log 2>&1 &
```

The `gsettings set` writes the key to the user database. Run it before the schema has the
key and it fails. In that case run it after starting the patched dock, with the same
`GSETTINGS_SCHEMA_DIR`. Afterwards, reset it with `gsettings reset io.elementary.dock stacks`
so that only the Nix default remains. Take a screenshot (`grim` on Wayland) and check
`dock.log` for any `Ignoring stack` lines or criticals. Report what you saw. Leave the
patched dock running: the user's own dock comes back on the next login or `pkill`.

- [ ] **Step 7: Commit**

```bash
git add modules/constellation/pantheon-dock-stacks
git commit -m "feat(modules): show folder stacks on the elementary dock as a grid"
```

---

### Task 4: The fan view

**Files:**
- Create: `modules/constellation/pantheon-dock-stacks/Stacks/StackStyle.vala`
- Create: `modules/constellation/pantheon-dock-stacks/Stacks/FanLayout.vala`
- Create: `modules/constellation/pantheon-dock-stacks/Stacks/FanPopover.vala`
- Modify: `modules/constellation/pantheon-dock-stacks/Stacks/StackItem.vala` (`create_popover`)
- Modify: `modules/constellation/pantheon-dock-stacks/Stacks/meson.build`

**Interfaces:**
- Consumes: `StackSource` (`entries`, `missing`, `open_location ()`), `StackEntry` (`name`, `icon`, `launch ()`, `attach_drag_source`).
- Produces: `Dock.FanPopover : Gtk.Popover` with `FanPopover (StackSource source)` and `const int MAX_ITEMS = 10`; `Dock.FanLayout : Gtk.Widget` with `append_row (Gtk.Widget)`, `clear ()`; `Dock.StackStyle.ensure ()`.

- [ ] **Step 1: Write `StackStyle.vala`**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The fan has no popover chrome: icons and pill labels float over the desktop.
 */

namespace Dock.StackStyle {
    private const string CSS = """
        popover.stack-fan > contents,
        popover.stack-fan > arrow {
            background: none;
            border: none;
            box-shadow: none;
            padding: 0;
        }

        .stack-fan-label {
            background: alpha(black, 0.7);
            color: white;
            border-radius: 9999px;
            padding: 3px 10px;
        }

        button.stack-fan-item {
            background: none;
            border: none;
            box-shadow: none;
            padding: 0;
        }

        button.stack-fan-item:hover .stack-fan-label,
        button.stack-fan-item:focus-visible .stack-fan-label {
            background: @accent_color;
        }
    """;

    private bool loaded = false;

    public void ensure () {
        if (loaded) {
            return;
        }
        loaded = true;

        var provider = new Gtk.CssProvider ();
        provider.load_from_string (CSS);
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }
}
```

- [ ] **Step 2: Write `FanLayout.vala`**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Rows stacked bottom-up on an arc: row 0 sits at the bottom, nearest the
 * dock, and each row above it drifts right and tilts a little more, the way a
 * macOS fan curves. Rows are right-aligned on their icon.
 */

public class Dock.FanLayout : Gtk.Widget {
    private const int ROW_HEIGHT = 56;
    private const double STEP_DEGREES = 2.0;
    // Horizontal drift of row i is ARC_RADIUS * (1 - cos (i * STEP)).
    private const double ARC_RADIUS = 1200;

    private GenericArray<Gtk.Widget> rows = new GenericArray<Gtk.Widget> ();

    construct {
        overflow = VISIBLE;
    }

    public void append_row (Gtk.Widget row) {
        row.set_parent (this);
        rows.add (row);
        queue_resize ();
    }

    public void clear () {
        foreach (var row in rows) {
            row.unparent ();
        }
        rows.length = 0;
        queue_resize ();
    }

    public override void dispose () {
        clear ();
        base.dispose ();
    }

    public override Gtk.SizeRequestMode get_request_mode () {
        return CONSTANT_SIZE;
    }

    public override void measure (Gtk.Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
        minimum_baseline = natural_baseline = -1;

        if (orientation == VERTICAL) {
            minimum = natural = ROW_HEIGHT * rows.length;
            return;
        }

        int widest = 0;
        foreach (var row in rows) {
            widest = int.max (widest, row_width (row));
        }
        minimum = natural = widest + (int) Math.ceil (drift (rows.length));
    }

    public override void size_allocate (int width, int height, int baseline) {
        var max_drift = drift (rows.length);
        for (uint i = 0; i < rows.length; i++) {
            var row = rows[i];
            var row_w = row_width (row);
            float right = (float) (width - (max_drift - drift (i + 1)));
            float middle = height - ROW_HEIGHT * (i + 0.5f);

            // Pivot on the row's right edge, where its icon is.
            var transform = new Gsk.Transform ()
                .translate ({ right, middle })
                .rotate (-(float) (i * STEP_DEGREES))
                .translate ({ -row_w, -ROW_HEIGHT / 2.0f });
            row.allocate (row_w, ROW_HEIGHT, -1, transform);
        }
    }

    private static int row_width (Gtk.Widget row) {
        int min, nat, min_b, nat_b;
        row.measure (HORIZONTAL, -1, out min, out nat, out min_b, out nat_b);
        return nat;
    }

    /* Drift of the row at 1-based height n; drift (rows.length) is the widest. */
    private static double drift (uint n) {
        if (n == 0) {
            return 0;
        }
        var radians = (n - 1) * STEP_DEGREES * Math.PI / 180.0;
        return ARC_RADIUS * (1 - Math.cos (radians));
    }
}
```

- [ ] **Step 3: Write `FanPopover.vala`**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * A stack opened as a fan: the newest MAX_ITEMS entries on an arc, newest
 * nearest the dock, with "Open in Files" and "N more…" above.
 */

public class Dock.FanPopover : Gtk.Popover {
    public const int MAX_ITEMS = 10;
    private const int ICON_SIZE = 48;

    public StackSource source { get; construct; }

    private FanLayout fan;
    private Gtk.Button more_button;
    private Gtk.Label message;

    public FanPopover (StackSource source) {
        Object (source: source, position: Gtk.PositionType.TOP, has_arrow: false);
    }

    construct {
        StackStyle.ensure ();
        add_css_class ("stack-fan");

        var open_button = create_pill_button (_("Open in Files"));
        open_button.clicked.connect (open_location);

        more_button = create_pill_button ("");
        more_button.clicked.connect (open_location);

        message = new Gtk.Label (null) {
            halign = END
        };
        message.add_css_class ("stack-fan-label");

        fan = new FanLayout () {
            margin_start = 24,
            margin_top = 12
        };

        var box = new Gtk.Box (VERTICAL, 6) {
            halign = END
        };
        box.append (open_button);
        box.append (more_button);
        box.append (message);
        box.append (fan);
        child = box;

        // We need to set offset because dock window's height is 1px larger than its visible area
        set_offset (0, -1);

        source.entries.items_changed.connect (rebuild);
        source.notify["missing"].connect (rebuild);
        rebuild ();
    }

    private Gtk.Button create_pill_button (string label) {
        var pill = new Gtk.Label (label);
        pill.add_css_class ("stack-fan-label");

        var button = new Gtk.Button () {
            child = pill,
            halign = END
        };
        button.add_css_class ("stack-fan-item");
        return button;
    }

    private void open_location () {
        popdown ();
        source.open_location ();
    }

    private void rebuild () {
        fan.clear ();

        var total = source.entries.get_n_items ();
        var shown = uint.min (total, MAX_ITEMS);
        for (uint i = 0; i < shown; i++) {
            fan.append_row (create_row ((StackEntry) source.entries.get_item (i)));
        }

        var extra = total - shown;
        more_button.visible = extra > 0;
        ((Gtk.Label) more_button.child).label = _("%u more…").printf (extra);

        message.visible = source.missing || total == 0;
        message.label = source.missing ? _("Folder not found") : _("No items");
    }

    private Gtk.Widget create_row (StackEntry entry) {
        var label = new Gtk.Label (entry.name) {
            ellipsize = MIDDLE,
            max_width_chars = 28
        };
        label.add_css_class ("stack-fan-label");

        var box = new Gtk.Box (HORIZONTAL, 8);
        box.append (label);
        box.append (new Gtk.Image.from_gicon (entry.icon) { pixel_size = ICON_SIZE });

        var button = new Gtk.Button () {
            child = box,
            tooltip_text = entry.name
        };
        button.add_css_class ("stack-fan-item");
        button.clicked.connect (() => {
            popdown ();
            entry.launch ();
        });
        StackEntry.attach_drag_source (button, () => entry);
        return button;
    }
}
```

- [ ] **Step 4: Route `view = fan` to the fan**

In `StackItem.vala` replace `create_popover` (including its comment) with:

```vala
    private Gtk.Popover create_popover () {
        switch (config.view) {
            case FAN: return new FanPopover (source);
            default: return new GridPopover (source);
        }
    }
```

Update `Stacks/meson.build`:

```meson
stacks_sources = stacks_core_sources + files(
    'FanLayout.vala',
    'FanPopover.vala',
    'GridPopover.vala',
    'StackItem.vala',
    'StackStore.vala',
    'StackStyle.vala',
)
```

- [ ] **Step 5: Build, then smoke-test on raider**

Run the dock build from the Development loop. Expected: PASS.

Repeat Task 3 Step 6, but set the Downloads stack's view to `fan`. Click the Downloads
stack, take a screenshot and check:
- newest file at the bottom;
- the arc drifts right as it rises;
- the labels are dark pills with no popover box behind them;
- "Open in Files" is on top.

If a frame or shadow shows behind the fan, that is the fallback the spec allows. Report it
with the screenshot rather than fighting the theme. Tuning `STEP_DEGREES`, `ARC_RADIUS` or
`ROW_HEIGHT` by eye is in scope; keep each change small.

- [ ] **Step 6: Commit**

```bash
git add modules/constellation/pantheon-dock-stacks
git commit -m "feat(modules): open the Downloads stack as a fan"
```

---

### Task 5: VM test

**Files:**
- Create: `tests/pantheon-dock-stacks-test.nix`
- Modify: `flake-modules/checks.nix` (inside the `optionalAttrs (system == "x86_64-linux")` block)

**Interfaces:**
- Consumes: `modules/constellation/pantheon-dock.nix` (imported alone; it is self-contained by design), its option `constellation.desktop.pantheon.dockStacks`.

- [ ] **Step 1: Write the test**

`tests/pantheon-dock-stacks-test.nix`:

```nix
# Boots Pantheon with the patched dock and two stacks, and checks that the
# dock comes up with them and survives an invalid stacks value.
# Modelled on nixpkgs' nixos/tests/pantheon.nix, but with LightDM autologin
# instead of typing into the greeter.
{pkgs, ...}: {
  name = "pantheon-dock-stacks";

  nodes.machine = {...}: {
    imports = [
      "${pkgs.path}/nixos/tests/common/user-account.nix"
      ../modules/constellation/pantheon-dock.nix
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

    constellation.desktop.pantheon.dockStacks = [
      {
        source = "~/Downloads";
        view = "fan";
        sort = "date-added";
      }
      {source = "applications";}
    ];

    systemd.tmpfiles.rules = ["d /home/alice/Downloads 0755 alice users -"];
  };

  testScript = {nodes, ...}: let
    user = nodes.machine.users.users.alice;
    bus = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString user.uid}/bus";
  in ''
    machine.wait_for_unit("display-manager.service")
    machine.wait_for_file("/run/user/${toString user.uid}/wayland-0")

    with subtest("The patched dock starts with the configured stacks"):
        machine.wait_until_succeeds("pgrep -x io.elementary.dock")
        machine.succeed("su - alice -c '${bus} gsettings get io.elementary.dock stacks' | grep -q applications")
        machine.sleep(10)
        machine.fail("journalctl -b -t io.elementary.dock | grep 'Ignoring stack'")
        machine.screenshot("dock_stacks")

    with subtest("An invalid stack is logged and skipped, and the dock stays up"):
        machine.succeed("su - alice -c \"${bus} gsettings set io.elementary.dock stacks \\\"[('~/Downloads', 'spiral', 'name', 'stack')]\\\"\"")
        machine.wait_until_succeeds("journalctl -b -t io.elementary.dock | grep \"Ignoring stack ~/Downloads: unknown view 'spiral'\"")
        machine.succeed("pgrep -x io.elementary.dock")
  '';
}
```

The quoting in the last subtest is fiddly. If it fights you, write the command into a
`pkgs.writeShellScript` in the test's `let` and call that instead. In this subtest the
logged source is the raw string `~/Downloads`, because `parse_all` logs the value before
it resolves it.

- [ ] **Step 2: Register it**

In `flake-modules/checks.nix`, inside the `optionalAttrs (system == "x86_64-linux") { … }` block, add:

```nix
        pantheon-dock-stacks-test = inputs.nixpkgs.legacyPackages.${system}.testers.nixosTest (
          import ../tests/pantheon-dock-stacks-test.nix
        );
```

- [ ] **Step 3: Run it**

```bash
git add -N tests/pantheon-dock-stacks-test.nix
nix build -L .#checks.x86_64-linux.pantheon-dock-stacks-test 2>&1 | tail -n 80
```

Expected: PASS. If the dock's warnings do not reach the journal under the identifier
`io.elementary.dock`, find where they went (`journalctl -b -o verbose | grep -B5 "Ignoring stack"`
via `machine.execute` and print it), then fix the grep. Do not weaken the assertion. If
autologin does not reach the session, copy upstream's greeter login (`ydotool` click +
`send_chars`) from `nixos/tests/pantheon.nix` in the nixpkgs input.

Look at the `dock_stacks` screenshot in `result/` and say what it shows.

- [ ] **Step 4: Format and commit**

```bash
just fmt
git add tests/pantheon-dock-stacks-test.nix flake-modules/checks.nix
git commit -m "test(modules): boot pantheon with dock stacks in a VM"
```

---

### Task 6: Deploy and verify on raider (controller, with the user)

Not for a subagent: this activates the user's own desktop, and the user confirms first.

- [ ] Ask the user, then `just deploy raider`.
- [ ] `pkill -x io.elementary.dock`. gnome-session restarts it from the new system profile. Check `readlink -f $(which io.elementary.dock)` names the new store path.
- [ ] `gsettings reset io.elementary.dock stacks` so the user database does not shadow the Nix default (Task 3/4 smoke tests may have written it).
- [ ] Screenshots: the dock with both stacks, the Downloads fan, the Applications grid.
- [ ] `curl -sLo ~/Downloads/stack-test.txt https://example.com`; the preview and fan update within a second.
- [ ] Drag a file out of the fan into a browser file input or Files; report whether it works. Popover autohide on Wayland may cancel the drag, and if so that is a finding to report, not a reason to ship a workaround unasked.
- [ ] Push to origin (`git push`) once verified.
- [ ] blackbird picks it up on its next deploy; mention that rather than deploying it.
