# Dock Stacks: App Folders, Download and Flathub Progress — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group the dock's Applications grid into category folders, show downloads in progress on the Downloads stack, and show AppCenter (Flathub) installs and updates on the Applications stack.

**Architecture:** All dock code is Vala under `modules/constellation/pantheon-dock/stacks/src/`, copied into the dock's `src/Stacks/` by the overlay in `modules/constellation/pantheon-dock/default.nix`; no upstream dock file changes, so `stacks/hooks.patch` is untouched. Display-free logic (folder classification, download state, the two progress feeds) goes in core files that the unit test links. AppCenter gets one new local patch, `pantheon-dock/appcenter/progress.patch`, applied in the same overlay, that publishes its jobs over its existing D-Bus object.

**Tech Stack:** Vala, GTK 4.22, libadwaita, Granite 7, GIO/GDBus, GLib.Test, meson; Nix (overlay via `pantheon.overrideScope`).

Spec: `docs/superpowers/specs/2026-10-31-dock-stacks-progress-design.md`. Read
`modules/constellation/pantheon-dock/CLAUDE.md` before starting: it holds the visual loop,
the Vala pitfalls that bit this code before, and the deploy order.

## Global Constraints

- Folders, in display order: **Games**, **System**, **Utilities**, **Terminal Tools**. Classification, first match wins: `Terminal=true` → Terminal Tools; `Game` → Games; `System` or `Settings` → System; `Utility` with none of `AudioVideo Audio Video Development Education Graphics Network Office Science` → Utilities; else top level. Hard-coded; no gsettings key, no Nix option.
- Folders apply only to `source = applications` with `view = grid`. A fan of applications stays flat.
- Folder cell label: `"<name> · <count>"`, e.g. `Games · 46`. Icon: first four children as a 2×2 mini-grid.
- Download suffixes: `.part`, `.crdownload`, `.download`. A 0-byte file `X` is hidden while `X.part` exists.
- Download refresh: once per second, only while a downloading entry exists. Stalled: not modified for **60 s**.
- Status strings, exactly: `Downloading · <size>`, `Stalled · <size>` (`format_size`), `Installing`, `Updating`, `Removing`.
- Busy entries: icon at opacity **0.5**. Progress `< 0` means indeterminate (pulsing).
- LauncherEntry progress counts only from apps whose `MimeType` lists `x-scheme-handler/https`, and only while the stack holds a `.crdownload`. Several values are averaged.
- AppCenter D-Bus additions on `io.elementary.appcenter` at `/io/elementary/appcenter`: signal `JobChanged (s component_id, s desktop_id, s name, s icon, u state, d progress)`, method `GetJobs () → a(ssssud)`. `state`: 0 idle/finished, 1 installing, 2 updating, 3 removing. Progress signals throttled to **4 Hz**.
- Provisional install cells sit **first** at the top level.
- Test hooks: `DOCK_STACKS_FOLDER=<folder name>`, `DOCK_STACKS_FAKE_JOB=<desktop-id>:<state>:<progress>`.
- Signal handlers on long-lived objects (`StackSource`, the two singletons, entries) are methods, never capturing lambdas; everything `StackItem` connects is disconnected in `teardown ()`; everything `StackSource` connects to a singleton is disconnected in `stop ()`.
- Never inject input to test; use the hooks.
- Commit straight to master (no branches, no worktrees). Conventional commits, scope `modules`. Never mention Claude.
- Run `just fmt` before committing any `.nix` change. New files are invisible to `nix build` until `git add`ed: `git add -N <path>` first.
- **`zoom/hooks.patch` may hold another session's uncommitted work.** Never stage or commit it. If a dock build fails inside zoom code, stop and ask the user.

## File Structure

```
modules/constellation/pantheon-dock/
  default.nix                         overlay also patches pantheon.appcenter; comment
  CLAUDE.md                           new hooks, progress feeds, the AppCenter patch
  appcenter/progress.patch   (new)    JobTracker + DBusServer JobChanged/GetJobs
  stacks/src/
    meson.build                       + AppFolders, LauncherProgress, AppCenterJobs (core);
                                        StackProgressBar, GridCell (widgets)
    AppFolders.vala         (new)     classify an app into a folder; pure
    LauncherProgress.vala   (new)     Unity LauncherEntry feed → download fraction
    AppCenterJobs.vala      (new)     AppCenter JobChanged/GetJobs feed
    StackEntry.vala                   folder kind, busy state, download state, launch rules
    StackSource.vala                  folders, previews, downloads, tile progress, jobs
    StackProgressBar.vala   (new)     thin progress bar that pulses when fraction < 0;
                                        StackBusy.bind () helper
    GridCell.vala           (new)     one grid cell: app/file/folder + busy state
    GridPopover.vala                  uses GridCell; folder page; Escape; folder hook
    FanPopover.vala                   status text + bar on rows
    StackPile.vala                    reads source.previews
    StackItem.vala                    previews model; tile bar; DOCK_STACKS_FOLDER
    StackStore.vala                   starts the two feeds
    StackStyle.vala                   progress bar, status, folder mini-grid CSS
    tests/StackTests.vala             all new unit tests
```

## Development loop (used by every task)

Build the dock. This also runs the stacks unit tests (`doCheck = true`), so a failing test
fails the build:

```bash
cd /home/arosenfeld/Code/nixos
nix build --no-link -L .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock 2>&1 | tail -n 60
```

Look at it on raider's live session (details and pitfalls in `pantheon-dock/CLAUDE.md`):

```bash
S=/tmp/claude-1000/-home-arosenfeld-Code-nixos/dock-progress && mkdir -p "$S"
just pantheon::dock-run "$S/dock.log" DOCK_STACKS_OPEN=1     # 1 = Applications, 0 = Downloads
just pantheon::shot "$S/grid.png" 1000 300 1500 1140         # popover area, physical px
just pantheon::shot "$S/tile.png" 1500 1240 600 200          # dock tiles close up
```

Read the PNGs with the Read tool. When finished, hand the session back to the stock dock:
`pkill -f '(^|/)io\.elementary\.dock$'` (the session respawns it).

---

### Task 1: Folder classification

**Files:**
- Create: `modules/constellation/pantheon-dock/stacks/src/AppFolders.vala`
- Modify: `modules/constellation/pantheon-dock/stacks/src/meson.build`
- Test: `modules/constellation/pantheon-dock/stacks/src/tests/StackTests.vala`

**Interfaces:**
- Produces: `Dock.AppFolders.Folder` enum `{ NONE, GAMES, SYSTEM, UTILITIES, TERMINAL }` with `string title ()`; `Folder AppFolders.classify (string? categories, bool terminal)`; `Folder AppFolders.classify_app (AppInfo app)`. Enum order is display order.

- [ ] **Step 1: Write the failing test**

In `tests/StackTests.vala`, add before `int main`:

```vala
void test_classify () {
    assert_true (AppFolders.classify ("Game;ActionGame;", false) == AppFolders.Folder.GAMES);
    assert_true (AppFolders.classify ("System;Monitor;", false) == AppFolders.Folder.SYSTEM);
    assert_true (AppFolders.classify ("Settings;", false) == AppFolders.Folder.SYSTEM);
    assert_true (AppFolders.classify ("Utility;", false) == AppFolders.Folder.UTILITIES);
    // A utility that is also an everyday app stays at the top level.
    assert_true (AppFolders.classify ("Utility;Office;", false) == AppFolders.Folder.NONE);
    assert_true (AppFolders.classify ("Network;WebBrowser;", false) == AppFolders.Folder.NONE);
    assert_true (AppFolders.classify (null, false) == AppFolders.Folder.NONE);
    // Terminal wins over everything else.
    assert_true (AppFolders.classify ("Game;", true) == AppFolders.Folder.TERMINAL);
    assert_cmpstr (AppFolders.Folder.TERMINAL.title (), EQ, "Terminal Tools");
}
```

And in `main`, after the last `Test.add_func`:

```vala
    Test.add_func ("/app-folders/classify", test_classify);
```

- [ ] **Step 2: Run it to verify it fails**

Run the dock build (Development loop). Expected: FAIL at compile time, `The name 'AppFolders' does not exist`.

- [ ] **Step 3: Implement**

Create `AppFolders.vala`:

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Which folder of the Applications grid an app belongs in, from its desktop
 * entry alone. Hard-coded on purpose: see
 * docs/superpowers/specs/2026-10-31-dock-stacks-progress-design.md.
 */

namespace Dock.AppFolders {
    /* NONE is the top level; the rest are in the order the folder cells appear. */
    public enum Folder {
        NONE,
        GAMES,
        SYSTEM,
        UTILITIES,
        TERMINAL;

        public string title () {
            switch (this) {
                case GAMES: return _("Games");
                case SYSTEM: return _("System");
                case UTILITIES: return _("Utilities");
                case TERMINAL: return _("Terminal Tools");
                default: return "";
            }
        }
    }

    // Main categories that make a Utility app an everyday one (a calculator
    // stays in Utilities, a note-taking app tagged Utility;Office does not).
    private const string[] EVERYDAY_CATEGORIES = {
        "AudioVideo", "Audio", "Video", "Development", "Education",
        "Graphics", "Network", "Office", "Science"
    };

    /* categories is the raw `Categories` value; the first matching rule wins. */
    public Folder classify (string? categories, bool terminal) {
        if (terminal) {
            return TERMINAL;
        }
        var cats = (categories ?? "").split (";");
        if ("Game" in cats) {
            return GAMES;
        }
        if ("System" in cats || "Settings" in cats) {
            return SYSTEM;
        }
        if ("Utility" in cats) {
            foreach (unowned var everyday in EVERYDAY_CATEGORIES) {
                if (everyday in cats) {
                    return NONE;
                }
            }
            return UTILITIES;
        }
        return NONE;
    }

    public Folder classify_app (AppInfo app) {
        var desktop = app as DesktopAppInfo;
        if (desktop == null) {
            return NONE;
        }
        return classify (desktop.get_categories (), desktop.get_boolean ("Terminal"));
    }
}
```

In `meson.build`, add `'AppFolders.vala',` as the first entry of `stacks_core_sources`.

- [ ] **Step 4: Run it to verify it passes**

Run the dock build. Expected: build succeeds; the log shows `/app-folders/classify` OK.

- [ ] **Step 5: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src/AppFolders.vala modules/constellation/pantheon-dock/stacks/src/meson.build modules/constellation/pantheon-dock/stacks/src/tests/StackTests.vala
git commit -m "feat(modules): classify dock Applications into folders"
```

---

### Task 2: Folder entries and previews in StackSource

**Files:**
- Modify: `stacks/src/StackEntry.vala`, `stacks/src/StackSource.vala`, `stacks/src/StackPile.vala`, `stacks/src/StackItem.vala`
- Test: `stacks/src/tests/StackTests.vala`

(All paths below are under `modules/constellation/pantheon-dock/`.)

**Interfaces:**
- Consumes: `AppFolders.classify_app`, `AppFolders.Folder.title ()` (Task 1).
- Produces:
  - `StackEntry.children : ListStore?` (non-null only for folders), `StackEntry.is_folder : bool`, `static StackEntry StackEntry.for_folder (string name, ListStore children)`.
  - `StackSource.previews : ListModel` — the top-level non-folder entries, in order. `StackPile` and the tile icon model read this instead of `entries`.
  - `StackSource.groups_folders : bool` (applications + grid).

- [ ] **Step 1: Write the failing tests**

Replace `write_desktop_files` in `tests/StackTests.vala` with:

```vala
void write_desktop_file (string apps, string id, string body) {
    try {
        FileUtils.set_contents (Path.build_filename (apps, id), "[Desktop Entry]\nType=Application\nExec=true\n" + body);
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}

void write_desktop_files (string data_dir) {
    var apps = Path.build_filename (data_dir, "applications");
    DirUtils.create_with_parents (apps, 0755);
    write_desktop_file (apps, "b.desktop", "Name=Beta\n");
    write_desktop_file (apps, "a.desktop", "Name=alpha\n");
    write_desktop_file (apps, "hidden.desktop", "Name=Hidden\nNoDisplay=true\n");
    write_desktop_file (apps, "web.desktop", "Name=Web\nCategories=Network;WebBrowser;\nMimeType=text/html;x-scheme-handler/https;\n");
    write_desktop_file (apps, "game.desktop", "Name=Gamma\nCategories=Game;\n");
    write_desktop_file (apps, "settings.desktop", "Name=Settings\nCategories=Settings;\n");
    write_desktop_file (apps, "calc.desktop", "Name=Calc\nCategories=Utility;\n");
    write_desktop_file (apps, "notes.desktop", "Name=Notes\nCategories=Utility;Office;\n");
    write_desktop_file (apps, "htop.desktop", "Name=Htop\nTerminal=true\nCategories=System;Monitor;\n");
}
```

Add a helper next to `entry_names`:

```vala
string[] model_names (ListModel model) {
    string[] names = {};
    for (uint i = 0; i < model.get_n_items (); i++) {
        names += ((StackEntry) model.get_item (i)).name;
    }
    return names;
}

StackEntry? find_entry (ListModel model, string name) {
    for (uint i = 0; i < model.get_n_items (); i++) {
        var entry = (StackEntry) model.get_item (i);
        if (entry.name == name) {
            return entry;
        }
    }
    return null;
}
```

Replace `test_applications` with:

```vala
void test_applications () {
    var source = new StackSource (new StackConfig (StackConfig.APPLICATIONS, GRID, NAME, STACK));
    wait_for_load (source);
    // Everyday apps A–Z, then the non-empty folders in fixed order; NoDisplay left out.
    assert_true (strv_equal (entry_names (source), {
        "alpha", "Beta", "Notes", "Web", "Games", "System", "Utilities", "Terminal Tools"
    }));
    assert_true (strv_equal (model_names (source.previews), { "alpha", "Beta", "Notes", "Web" }));

    var utilities = find_entry (source.entries, "Utilities");
    assert_true (utilities.is_folder);
    assert_true (strv_equal (model_names (utilities.children), { "Calc" }));
    assert_true (strv_equal (model_names (find_entry (source.entries, "System").children), { "Settings" }));
    assert_true (strv_equal (model_names (find_entry (source.entries, "Terminal Tools").children), { "Htop" }));
    assert_true (strv_equal (model_names (find_entry (source.entries, "Games").children), { "Gamma" }));
}

void test_applications_fan_flat () {
    var source = new StackSource (new StackConfig (StackConfig.APPLICATIONS, FAN, NAME, STACK));
    wait_for_load (source);
    assert_true (strv_equal (entry_names (source), {
        "alpha", "Beta", "Calc", "Gamma", "Htop", "Notes", "Settings", "Web"
    }));
    assert_true (strv_equal (model_names (source.previews), entry_names (source)));
}
```

Register the new test in `main`:

```vala
    Test.add_func ("/stack-source/applications-fan-flat", test_applications_fan_flat);
```

- [ ] **Step 2: Run them to verify they fail**

Dock build. Expected: FAIL at compile time (`previews`, `is_folder`, `children` do not exist).

- [ ] **Step 3: Implement StackEntry folder kind**

In `StackEntry.vala`, add after the `added_usec` property:

```vala
    /* A folder of the Applications grid: its apps, A–Z. Null for anything else. */
    public ListStore? children { get; construct; }

    public bool is_folder { get { return children != null; } }
```

Add after `from_app`:

```vala
    public static StackEntry for_folder (string name, ListStore children) {
        return (StackEntry) Object.new (
            typeof (StackEntry),
            name: name,
            icon: new ThemedIcon ("folder"),
            children: children,
            added_usec: 0
        );
    }
```

At the top of `launch ()`, add:

```vala
        if (is_folder) {
            // A folder opens inside the popover; GridPopover handles it.
            return;
        }
```

- [ ] **Step 4: Implement grouping in StackSource**

In `StackSource.vala`:

Add next to `entries`:

```vala
    /* The top-level entries that are not folders, for the tile's preview. */
    public ListModel previews { get { return preview_store; } }

    /* Applications shown as a grid are grouped into AppFolders. */
    public bool groups_folders { get { return config.is_applications && config.view == GRID; } }
```

Add the field `private ListStore preview_store;`, and in `construct` after `store = ...`:

```vala
        preview_store = new ListStore (typeof (StackEntry));
```

In `stop ()`, after `store.remove_all ();` add `preview_store.remove_all ();`.

In `reload ()`, replace everything from `loaded_entries.sort (...)` to `store.splice (...)` with:

```vala
        loaded_entries.sort (config.sort == NAME ? (CompareFunc<StackEntry>) compare_name : (CompareFunc<StackEntry>) compare_newest_first);

        Object[] items = {};
        Object[] previews = {};
        if (groups_folders) {
            var folders = new GenericArray<ListStore> ();
            for (int f = 0; f <= AppFolders.Folder.TERMINAL; f++) {
                folders.add (new ListStore (typeof (StackEntry)));
            }
            foreach (var entry in loaded_entries) {
                var folder = AppFolders.classify_app (entry.app);
                if (folder == NONE) {
                    items += entry;
                    previews += entry;
                } else {
                    folders[folder].append (entry);
                }
            }
            for (int f = AppFolders.Folder.GAMES; f <= AppFolders.Folder.TERMINAL; f++) {
                if (folders[f].get_n_items () > 0) {
                    items += StackEntry.for_folder (((AppFolders.Folder) f).title (), folders[f]);
                }
            }
        } else {
            foreach (var entry in loaded_entries) {
                items += entry;
                previews += entry;
            }
        }
        preview_store.splice (0, preview_store.get_n_items (), previews);
        store.splice (0, store.get_n_items (), items);
```

- [ ] **Step 5: Point the tile at previews**

In `StackItem.vala` constructor: `icons: new Gtk.MapListModel (source.previews, entry_icon),`.

In `StackPile.vala`, replace every `source.entries` with `source.previews` (lines 41, 48, 71, 74).

- [ ] **Step 6: Run the tests to verify they pass**

Dock build. Expected: all tests pass, including `/stack-source/applications` and `/stack-source/applications-fan-flat`.

- [ ] **Step 7: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src
git commit -m "feat(modules): group the dock Applications stack into folders"
```

---

### Task 3: Progress bar widget, grid cells and the folder page

**Files:**
- Create: `stacks/src/StackProgressBar.vala`, `stacks/src/GridCell.vala`
- Modify: `stacks/src/StackEntry.vala`, `stacks/src/GridPopover.vala`, `stacks/src/StackItem.vala`, `stacks/src/StackStyle.vala`, `stacks/src/meson.build`

**Interfaces:**
- Consumes: `StackEntry.children`, `StackEntry.is_folder` (Task 2).
- Produces:
  - `StackEntry` busy state: `string? status_text { get; set; }` (null = not busy), `double progress { get; set; default = -1; }` (< 0 = indeterminate), `bool show_progress { get; set; }`.
  - `Dock.StackProgressBar : Gtk.Widget` with `double fraction { get; set; default = -1; }`.
  - `Dock.StackBusy.bind (StackEntry entry, Gtk.Widget icon, Gtk.Label status, Gtk.Revealer bar_revealer, StackProgressBar bar, GenericArray<Binding> bindings)`.
  - `Dock.GridCell : Gtk.Box` with `StackEntry? entry { get; set; }`, constructor `GridCell (int width, int text_height)`.
  - `GridPopover.open_folder_for_test (string name)`.

No unit test: everything here is a widget. The check is visual.

- [ ] **Step 1: Busy state on StackEntry**

In `StackEntry.vala`, after `is_folder`:

```vala
    /*
     * Busy state, shared by downloads and AppCenter jobs. A non-null
     * status_text ("Downloading · 34 MB", "Installing") marks the entry busy:
     * its icon is dimmed and the text shown. progress < 0 pulses.
     */
    public string? status_text { get; set; default = null; }
    public double progress { get; set; default = -1; }
    public bool show_progress { get; set; default = false; }
```

- [ ] **Step 2: Create StackProgressBar.vala**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The thin progress bar of a stack tile, fan row or grid cell, styled like
 * upstream Launcher's Unity bar. A fraction below 0 pulses it.
 */

public class Dock.StackProgressBar : Gtk.Widget {
    private const int64 PULSE_USEC = 120000;

    /* 0–1, or below 0 for indeterminate. */
    public double fraction { get; set; default = -1; }

    private Gtk.ProgressBar bar;
    private uint tick_id = 0;
    private int64 last_pulse = 0;

    class construct {
        set_layout_manager_type (typeof (Gtk.BinLayout));
    }

    construct {
        bar = new Gtk.ProgressBar () {
            pulse_step = 0.15
        };
        bar.add_css_class ("stack-progress");
        bar.set_parent (this);
        notify["fraction"].connect (update_fraction);
        update_fraction ();
    }

    public override void dispose () {
        if (bar != null) {
            bar.unparent ();
            bar = null;
        }
        base.dispose ();
    }

    // Pulse only while on screen: the tick callback holds this widget, and is
    // dropped in unmap, which GTK always runs before the widget goes away.
    public override void map () {
        base.map ();
        tick_id = add_tick_callback (on_tick);
    }

    public override void unmap () {
        if (tick_id != 0) {
            remove_tick_callback (tick_id);
            tick_id = 0;
        }
        base.unmap ();
    }

    private bool on_tick (Gtk.Widget widget, Gdk.FrameClock clock) {
        if (fraction < 0) {
            var now = clock.get_frame_time ();
            if (now - last_pulse >= PULSE_USEC) {
                bar.pulse ();
                last_pulse = now;
            }
        }
        return Source.CONTINUE;
    }

    private void update_fraction () {
        if (fraction >= 0) {
            bar.fraction = fraction.clamp (0, 1);
        }
    }
}

namespace Dock.StackBusy {
    /*
     * Shows entry's busy state on a cell's widgets: dims icon, fills status,
     * and reveals the bar. The bindings are added to `bindings` so a recycled
     * grid cell can unbind them; a fan row just lets them die with it.
     */
    public void bind (StackEntry entry, Gtk.Widget icon, Gtk.Label status, Gtk.Revealer bar_revealer,
                      StackProgressBar bar, GenericArray<Binding> bindings) {
        bindings.add (entry.bind_property ("status-text", icon, "opacity", SYNC_CREATE, busy_to_opacity));
        bindings.add (entry.bind_property ("status-text", status, "label", SYNC_CREATE, null_to_empty));
        bindings.add (entry.bind_property ("status-text", status, "visible", SYNC_CREATE, is_busy));
        bindings.add (entry.bind_property ("show-progress", bar_revealer, "reveal-child", SYNC_CREATE));
        bindings.add (entry.bind_property ("progress", bar, "fraction", SYNC_CREATE));
    }

    public bool is_busy (Binding binding, Value from, ref Value to) {
        to.set_boolean (from.get_string () != null);
        return true;
    }

    private bool busy_to_opacity (Binding binding, Value from, ref Value to) {
        to.set_double (from.get_string () != null ? 0.5 : 1.0);
        return true;
    }

    private bool null_to_empty (Binding binding, Value from, ref Value to) {
        to.set_string (from.get_string () ?? "");
        return true;
    }

    /* A crossfading revealer around a new bar, aligned to the bottom of an icon. */
    public Gtk.Revealer new_bar_revealer (out StackProgressBar bar) {
        bar = new StackProgressBar ();
        return new Gtk.Revealer () {
            child = bar,
            can_target = false,
            transition_type = CROSSFADE,
            valign = END
        };
    }
}
```

- [ ] **Step 3: Create GridCell.vala**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * One cell of a GridPopover: an app, a file, or a folder of apps, plus its
 * busy state. Grid cells are recycled, so `entry` changes and the bindings
 * follow it.
 */

public class Dock.GridCell : Gtk.Box {
    public const int ICON_SIZE = 48;
    private const int MINI_ICON_SIZE = 20;

    public StackEntry? entry { get; set; }
    /* Two lines of label: the text area's fixed height. */
    public int text_height { get; construct; }

    private Gtk.Stack icon_stack;
    private Gtk.Image image;
    private Gtk.Image[] mini_images = {};
    private Gtk.Revealer bar_revealer;
    private StackProgressBar bar;
    private Gtk.Label name_label;
    private Gtk.Label status_label;
    private GenericArray<Binding> bindings = new GenericArray<Binding> ();

    /* width: the cell's content width. */
    public GridCell (int width, int text_height) {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 6,
            width_request: width,
            valign: Gtk.Align.START,
            text_height: text_height
        );
    }

    // Set-up lives in construct, not the creation method: valac runs only
    // property assignments for a GObject-style creation method's chain-up.
    construct {
        image = new Gtk.Image () { pixel_size = ICON_SIZE };
        image.add_css_class ("stack-icon");

        var mini_grid = new Gtk.Grid () {
            row_spacing = 4,
            column_spacing = 4,
            halign = CENTER,
            valign = CENTER,
            width_request = ICON_SIZE,
            height_request = ICON_SIZE
        };
        mini_grid.add_css_class ("stack-folder-icon");
        for (int i = 0; i < 4; i++) {
            var mini = new Gtk.Image () { pixel_size = MINI_ICON_SIZE };
            mini_grid.attach (mini, i % 2, i / 2);
            mini_images += mini;
        }

        icon_stack = new Gtk.Stack () { halign = CENTER };
        icon_stack.add_named (image, "icon");
        icon_stack.add_named (mini_grid, "folder");

        bar_revealer = StackBusy.new_bar_revealer (out bar);
        var icon = new Gtk.Overlay () { child = icon_stack, halign = CENTER };
        icon.add_overlay (bar_revealer);
        append (icon);

        // Wraps to two lines before ellipsizing; width_chars keeps every
        // cell's label the same width, so the columns stay aligned.
        name_label = new Gtk.Label (null) {
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            lines = 2,
            ellipsize = END,
            width_chars = 12,
            max_width_chars = 12,
            justify = CENTER,
            yalign = 0
        };
        status_label = new Gtk.Label (null) {
            ellipsize = END,
            max_width_chars = 12,
            visible = false
        };
        status_label.add_css_class ("stack-status");

        // Two lines tall whatever is in it, so all rows are the same height.
        var text = new Gtk.Box (VERTICAL, 0) { height_request = text_height, valign = START };
        text.append (name_label);
        text.append (status_label);
        append (text);

        notify["entry"].connect (rebind);
        attach_drag (this);
    }

    // Static, so the getter cannot capture `this`: the cell owns the drag
    // source, and a closure over the cell would keep it alive forever.
    private static void attach_drag (GridCell cell) {
        unowned var weak_cell = cell;
        StackEntry.attach_drag_source (cell, () => weak_cell.entry);
    }

    private void rebind () {
        foreach (var binding in bindings) {
            binding.unbind ();
        }
        bindings.length = 0;

        if (entry == null) {
            return;
        }

        if (entry.is_folder) {
            var n = entry.children.get_n_items ();
            for (uint i = 0; i < mini_images.length; i++) {
                mini_images[i].gicon = i < n ? ((StackEntry) entry.children.get_item (i)).icon : null;
            }
            icon_stack.visible_child_name = "folder";
            name_label.label = "%s · %u".printf (entry.name, n);
        } else {
            image.gicon = entry.icon;
            icon_stack.visible_child_name = "icon";
            name_label.label = entry.name;
        }

        StackBusy.bind (entry, icon_stack, status_label, bar_revealer, bar, bindings);
        // A busy cell gives its second line to the status.
        bindings.add (entry.bind_property ("status-text", name_label, "lines", SYNC_CREATE, busy_to_lines));
    }

    private static bool busy_to_lines (Binding binding, Value from, ref Value to) {
        to.set_int (from.get_string () != null ? 1 : 2);
        return true;
    }
}
```

- [ ] **Step 4: Rewrite GridPopover around GridCell, with a folder page**

Replace `GridPopover.vala` from `public StackSource source` to the end of the file with:

```vala
    public StackSource source { get; construct; }

    private Gtk.Stack content;
    private Gtk.Label message;
    private Gtk.GridView folder_grid;
    private Gtk.Label folder_title;

    public GridPopover (StackSource source) {
        Object (source: source, position: Gtk.PositionType.TOP);
    }

    construct {
        StackStyle.ensure ();
        add_css_class ("stack-grid");

        var grid = create_grid (source.entries);
        grid.activate.connect (on_activate);

        folder_grid = create_grid (null);
        folder_grid.activate.connect (on_folder_activate);

        var back = new Gtk.Button.with_label (_("Applications")) {
            halign = START
        };
        back.add_css_class ("back-button");
        back.clicked.connect (close_folder);

        folder_title = new Gtk.Label (null) {
            hexpand = true,
            xalign = 0
        };
        folder_title.add_css_class ("title-4");

        var header = new Gtk.Box (HORIZONTAL, 12) {
            margin_bottom = 6
        };
        header.append (back);
        header.append (folder_title);

        var folder_page = new Gtk.Box (VERTICAL, 0);
        folder_page.append (header);
        folder_page.append (create_scrolled (folder_grid));

        message = new Gtk.Label (null) {
            margin_top = 24,
            margin_bottom = 24,
            margin_start = 24,
            margin_end = 24
        };
        message.add_css_class (Granite.STYLE_CLASS_DIM_LABEL);

        content = new Gtk.Stack () {
            transition_type = SLIDE_LEFT_RIGHT
        };
        content.add_named (create_scrolled (grid), "grid");
        content.add_named (folder_page, "folder");
        content.add_named (message, "message");
        child = content;

        // Escape inside a folder goes back to the top level instead of closing.
        // Capture phase: the popover's own Escape shortcut would win otherwise.
        var keys = new Gtk.EventControllerKey () {
            propagation_phase = CAPTURE
        };
        keys.key_pressed.connect (on_key_pressed);
        add_controller (keys);
        closed.connect (on_closed);

        // We need to set offset because dock window's height is 1px larger than its visible area
        set_offset (0, -1);

        // Methods, not capturing lambdas: a closure over a local would keep this
        // popover alive for as long as the source is.
        source.notify["missing"].connect (update_message);
        source.entries.items_changed.connect (update_message);
        update_message ();
    }

    ~GridPopover () {
        source.notify["missing"].disconnect (update_message);
        source.entries.items_changed.disconnect (update_message);
    }

    private static Gtk.GridView create_grid (ListModel? model) {
        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect (setup_cell);
        factory.bind.connect (bind_cell);
        factory.unbind.connect (unbind_cell);

        return new Gtk.GridView (model == null ? null : new Gtk.NoSelection (model), factory) {
            min_columns = COLUMNS,
            max_columns = COLUMNS,
            single_click_activate = true
        };
    }

    private static Gtk.ScrolledWindow create_scrolled (Gtk.GridView grid) {
        return new Gtk.ScrolledWindow () {
            child = grid,
            hscrollbar_policy = NEVER,
            width_request = (CELL_WIDTH + CELL_EXTRA_WIDTH) * COLUMNS,
            // Whole rows only: a row cut through its labels looks broken, not scrollable.
            max_content_height = (ICON_SIZE + SPACING + two_line_height () + CELL_EXTRA_HEIGHT) * VISIBLE_ROWS,
            propagate_natural_height = true
        };
    }

    private static void setup_cell (Object obj) {
        ((Gtk.ListItem) obj).child = new GridCell (CELL_WIDTH, two_line_height ());
    }

    private static void bind_cell (Object obj) {
        var list_item = (Gtk.ListItem) obj;
        ((GridCell) list_item.child).entry = (StackEntry) list_item.item;
    }

    private static void unbind_cell (Object obj) {
        ((GridCell) ((Gtk.ListItem) obj).child).entry = null;
    }

    private static int label_height = 0;

    /* The height of a two-line label in the current font. */
    private static int two_line_height () {
        if (label_height == 0) {
            var probe = new Gtk.Label ("X\nX");
            int min, nat, min_b, nat_b;
            probe.measure (VERTICAL, -1, out min, out nat, out min_b, out nat_b);
            label_height = nat;
        }
        return label_height;
    }

    private void on_activate (uint position) {
        activate_entry ((StackEntry) source.entries.get_item (position));
    }

    private void on_folder_activate (uint position) {
        activate_entry ((StackEntry) folder_grid.model.get_item (position));
    }

    private void activate_entry (StackEntry entry) {
        if (entry.is_folder) {
            open_folder (entry);
            return;
        }
        popdown ();
        source.launched ();
        entry.launch ();
    }

    private void open_folder (StackEntry folder) {
        folder_grid.model = new Gtk.NoSelection (folder.children);
        folder_title.label = folder.name;
        content.visible_child_name = "folder";
    }

    private void close_folder () {
        content.visible_child_name = "grid";
    }

    private bool on_key_pressed (uint keyval, uint keycode, Gdk.ModifierType state) {
        if (keyval == Gdk.Key.Escape && content.visible_child_name == "folder") {
            close_folder ();
            return true;
        }
        return false;
    }

    // Reopening always starts at the top level, without a slide.
    private void on_closed () {
        content.transition_type = NONE;
        update_message ();
        content.transition_type = SLIDE_LEFT_RIGHT;
    }

    /* Test hook for DOCK_STACKS_FOLDER (see StackItem). */
    public void open_folder_for_test (string name) {
        var folder = find_folder (name);
        if (folder == null) {
            warning ("DOCK_STACKS_FOLDER: no folder '%s'", name);
            return;
        }
        open_folder (folder);
    }

    private StackEntry? find_folder (string name) {
        for (uint i = 0; i < source.entries.get_n_items (); i++) {
            var entry = (StackEntry) source.entries.get_item (i);
            if (entry.is_folder && entry.name == name) {
                return entry;
            }
        }
        return null;
    }

    private void update_message () {
        if (source.missing) {
            message.label = _("Folder not found");
            content.visible_child_name = "message";
        } else if (source.entries.get_n_items () == 0) {
            message.label = _("No items");
            content.visible_child_name = "message";
        } else if (content.visible_child_name == "folder" && get_mapped ()) {
            // A reload replaced the folder entries: follow the open folder to its
            // new object, or go back if it emptied.
            var folder = find_folder (folder_title.label);
            if (folder != null) {
                open_folder (folder);
            } else {
                content.visible_child_name = "grid";
            }
        } else {
            content.visible_child_name = "grid";
        }
    }
}
```

Keep the existing header comment, the class line and the constants block (`COLUMNS` … `CELL_EXTRA_HEIGHT`) above it unchanged.

- [ ] **Step 5: The DOCK_STACKS_FOLDER hook**

In `StackItem.vala`, in `open_for_test ()` after `popover_menu.popup ();`:

```vala
        var folder = Environment.get_variable ("DOCK_STACKS_FOLDER");
        if (folder != null && popover_menu is GridPopover) {
            ((GridPopover) popover_menu).open_folder_for_test (folder);
        }
```

Extend the hook comment above `maybe_open_for_test` with one sentence: `With DOCK_STACKS_FOLDER=<folder name> too, an Applications grid opens that folder.`

- [ ] **Step 6: CSS**

In `StackStyle.vala`, append inside `CSS` before the closing `"""`:

```css
        /* Upstream Launcher's progress bar (data/Application.css), for stack
         * tiles, fan rows and grid cells. */
        progressbar.stack-progress {
            margin: 0 6px 4px 6px;
        }

        progressbar.stack-progress trough {
            background: #333;
            border: none;
            border-radius: 99px;
            box-shadow: none;
            min-height: 3px;
            padding: 1px;
        }

        progressbar.stack-progress progress {
            background: white;
            border: none;
            border-radius: 99px;
            box-shadow: none;
            margin: 0;
            min-height: 3px;
            min-width: 0;
        }

        icongroup.stack progressbar.stack-progress {
            margin-bottom: 6px;
        }

        .stack-status {
            font-size: smaller;
            opacity: 0.7;
        }

        .stack-folder-icon {
            background: alpha(currentColor, 0.08);
            border-radius: 12px;
            padding: 2px;
        }
```

- [ ] **Step 7: meson**

In `meson.build`, add `'GridCell.vala',` and `'StackProgressBar.vala',` to the widget list after `stacks_core_sources + files(` (alphabetical with the others). Then `git add -N` both new files.

- [ ] **Step 8: Build and look**

Dock build, then:

```bash
just pantheon::dock-run "$S/dock.log" DOCK_STACKS_OPEN=1
just pantheon::shot "$S/grid-top.png" 1000 300 1500 1140
just pantheon::dock-run "$S/dock.log" DOCK_STACKS_OPEN=1 DOCK_STACKS_FOLDER=Games
just pantheon::shot "$S/grid-games.png" 1000 300 1500 1140
```

Read both PNGs. Expected: top level shows everyday apps A–Z, then four folder cells with 2×2 mini icons labelled like `Games · 46`; the Games capture shows the back button, the title and the games. Rows the same height as before; no clipped labels. Check `$S/dock.log` has no new `CRITICAL` or `WARNING` lines. Fix and repeat until it looks right.

- [ ] **Step 9: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src
git commit -m "feat(modules): open dock Applications folders in the grid"
```

---

### Task 4: Downloads in progress in StackSource

**Files:**
- Modify: `stacks/src/StackEntry.vala`, `stacks/src/StackSource.vala`
- Test: `stacks/src/tests/StackTests.vala`

**Interfaces:**
- Consumes: `StackEntry.status_text`, `progress`, `show_progress` (Task 3).
- Produces:
  - `StackEntry.downloading : bool` (construct), `bytes : uint64`, `stalled : bool`, `void update_download (uint64 bytes, int64 modified_usec, int64 now_usec)`, `const int64 STALL_USEC`.
  - `static string? StackSource.download_suffix (string name)`; `StackSource.is_shown_name` now only hides dot-files.

- [ ] **Step 1: Write the failing tests**

In `tests/StackTests.vala`, replace `make_folder` with a version that spaces the files out (so date-added never ties) and records the download fixtures:

```vala
void make_file (string dir, string name, string contents = "x") {
    try {
        FileUtils.set_contents (Path.build_filename (dir, name), contents);
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
    Thread.usleep (20000);
}

string make_folder () {
    try {
        var dir = DirUtils.make_tmp ("stacks-XXXXXX");
        // alpha.pdf is created first, so it is older but sorts first by name.
        make_file (dir, "alpha.pdf");
        make_file (dir, "zeta.zip");
        make_file (dir, ".hidden");
        make_file (dir, "big.iso.part");
        make_file (dir, "video.mp4.crdownload");
        make_file (dir, "safari.download");
        return dir;
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}
```

Replace `test_shown_names`, `test_folder_date_added`, `test_folder_name` and the expectation in `test_folder_live_update` with:

```vala
void test_shown_names () {
    assert_true (StackSource.is_shown_name ("report.pdf"));
    assert_true (StackSource.is_shown_name ("a.part"));
    assert_false (StackSource.is_shown_name (".hidden"));
    assert_cmpstr (StackSource.download_suffix ("a.part"), EQ, ".part");
    assert_cmpstr (StackSource.download_suffix ("a.crdownload"), EQ, ".crdownload");
    assert_cmpstr (StackSource.download_suffix ("a.download"), EQ, ".download");
    assert_null (StackSource.download_suffix ("a.pdf"));
}

void test_folder_date_added () {
    var source = new StackSource (new StackConfig (make_folder (), FAN, DATE_ADDED, STACK));
    wait_for_load (source);
    assert_false (source.missing);
    assert_true (strv_equal (entry_names (source), { "safari", "video.mp4", "big.iso", "zeta.zip", "alpha.pdf" }));
    var video = (StackEntry) source.entries.get_item (1);
    assert_true (video.downloading);
    assert_true (video.status_text.has_prefix ("Downloading · "));
    assert_true (video.show_progress);
    assert_false (((StackEntry) source.entries.get_item (3)).downloading);
}

void test_folder_name () {
    var source = new StackSource (new StackConfig (make_folder (), GRID, NAME, STACK));
    wait_for_load (source);
    assert_true (strv_equal (entry_names (source), { "alpha.pdf", "big.iso", "safari", "video.mp4", "zeta.zip" }));
}
```

In `test_folder_live_update`, the final assertion becomes:

```vala
    assert_true (strv_equal (entry_names (source), { "newest.txt", "safari", "video.mp4", "big.iso", "zeta.zip", "alpha.pdf" }));
```

Add:

```vala
void test_firefox_placeholder_hidden () {
    try {
        var dir = DirUtils.make_tmp ("stacks-XXXXXX");
        make_file (dir, "empty.txt", "");          // a 0-byte file on its own stays
        make_file (dir, "movie.mkv", "");          // Firefox's placeholder…
        make_file (dir, "movie.mkv.part", "abc");  // …for this download
        var source = new StackSource (new StackConfig (dir, FAN, NAME, STACK));
        wait_for_load (source);
        assert_true (strv_equal (entry_names (source), { "empty.txt", "movie.mkv" }));
        var movie = (StackEntry) source.entries.get_item (1);
        assert_true (movie.downloading);
        assert_cmpuint ((uint) movie.bytes, EQ, 3);
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}

void test_download_stall () {
    var entry = new StackEntry ("x.iso", new ThemedIcon ("text-x-generic"), null, null, 0);
    var now = get_real_time ();
    entry.update_download (1024, now - StackEntry.STALL_USEC - 1000000, now);
    assert_true (entry.stalled);
    assert_false (entry.show_progress);
    assert_cmpstr (entry.status_text, EQ, "Stalled · 1.0 kB");

    entry.update_download (2048, now, now);
    assert_false (entry.stalled);
    assert_true (entry.show_progress);
    assert_cmpstr (entry.status_text, EQ, "Downloading · 2.0 kB");
}
```

Register them:

```vala
    Test.add_func ("/stack-source/firefox-placeholder", test_firefox_placeholder_hidden);
    Test.add_func ("/stack-entry/download-stall", test_download_stall);
```

- [ ] **Step 2: Run them to verify they fail**

Dock build. Expected: FAIL at compile time (`download_suffix`, `downloading`, `update_download` do not exist).

- [ ] **Step 3: StackEntry download state**

In `StackEntry.vala`, add after `show_progress`:

```vala
    /* A file that has not grown for this long is a leftover, not a download. */
    public const int64 STALL_USEC = 60 * 1000000;

    /* An in-progress download (.part, .crdownload, .download); `file` is the partial file. */
    public bool downloading { get; construct; default = false; }
    public uint64 bytes { get; set; }
    public bool stalled { get; set; }

    public void update_download (uint64 bytes, int64 modified_usec, int64 now_usec) {
        this.bytes = bytes;
        stalled = now_usec - modified_usec > STALL_USEC;
        var size = format_size (bytes);
        status_text = stalled ? _("Stalled · %s").printf (size) : _("Downloading · %s").printf (size);
        show_progress = !stalled;
        progress = -1;
    }
```

Replace `from_file_info` with:

```vala
    public static StackEntry from_file_info (File file, FileInfo info) {
        Icon icon = info.get_icon () ?? new ThemedIcon ("text-x-generic");
        var thumbnail = info.get_attribute_byte_string (FileAttribute.THUMBNAIL_PATH);
        if (thumbnail != null) {
            icon = new FileIcon (File.new_for_path (thumbnail));
        }

        var modified = (int64) info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED) * 1000000
            + info.get_attribute_uint32 (FileAttribute.TIME_MODIFIED_USEC);
        int64 added;
        if (info.has_attribute (FileAttribute.TIME_CREATED)) {
            added = (int64) info.get_attribute_uint64 (FileAttribute.TIME_CREATED) * 1000000
                + info.get_attribute_uint32 (FileAttribute.TIME_CREATED_USEC);
        } else {
            added = modified;
        }

        var name = info.get_display_name ();
        var suffix = StackSource.download_suffix (info.get_name ());
        if (suffix == null) {
            return new StackEntry (name, icon, file, null, added);
        }

        var entry = (StackEntry) Object.new (
            typeof (StackEntry),
            name: name.has_suffix (suffix) ? name.substring (0, name.length - suffix.length) : name,
            icon: icon,
            file: file,
            added_usec: added,
            downloading: true
        );
        entry.update_download (info.get_size (), modified, get_real_time ());
        return entry;
    }
```

In `launch ()`, after the `is_folder` early return, add:

```vala
        if (downloading) {
            // Not done yet: show it in its folder instead of opening half a file.
            open_uri (file.get_parent ().get_uri ());
            return;
        }
```

and add, after `launch ()`:

```vala
    private static void open_uri (string uri) {
        try {
            AppInfo.launch_default_for_uri (uri, Gdk.Display.get_default ().get_app_launch_context ());
        } catch (Error e) {
            critical ("Failed to open %s: %s", uri, e.message);
        }
    }
```

In `attach_drag_source`, change the `prepare` guard to:

```vala
            if (entry == null || entry.file == null || entry.downloading) {
```

- [ ] **Step 4: StackSource keeps downloads and refreshes them**

In `StackSource.vala`:

Add `standard::size` to `FILE_ATTRIBUTES` (after `standard::is-backup,`).

Add constants and fields:

```vala
    private const string[] DOWNLOAD_SUFFIXES = { ".part", ".crdownload", ".download" };
    private const string REFRESH_ATTRIBUTES = "standard::size,time::modified,time::modified-usec";
    private uint refresh_id = 0;
```

Replace `is_shown_name` with:

```vala
    public static bool is_shown_name (string name) {
        return !name.has_prefix (".");
    }

    /* The in-progress download suffix of name, or null for a finished file. */
    public static string? download_suffix (string name) {
        foreach (unowned var suffix in DOWNLOAD_SUFFIXES) {
            if (name.has_suffix (suffix)) {
                return suffix;
            }
        }
        return null;
    }
```

Replace `on_monitor_changed` with:

```vala
    private void on_monitor_changed (File file, File? other, FileMonitorEvent event) {
        // A download writes its partial file many times a second; refresh_downloads
        // follows its size, so only its creation, rename and deletion reload.
        var content_only = event == CHANGED || event == CHANGES_DONE_HINT || event == ATTRIBUTE_CHANGED;
        if (content_only && download_suffix (file.get_basename ()) != null) {
            return;
        }
        queue_reload ();
    }
```

Replace the body of `load_folder`'s `try` block with one that hides Firefox placeholders:

```vala
            var enumerator = yield dir.enumerate_children_async (FILE_ATTRIBUTES, NONE, Priority.DEFAULT, cancellable);
            missing = false;

            var infos = new GenericArray<FileInfo> ();
            var names = new GenericSet<string> (str_hash, str_equal);
            List<FileInfo> batch;
            while ((batch = yield enumerator.next_files_async (64, Priority.DEFAULT, cancellable)) != null) {
                foreach (var info in batch) {
                    infos.add (info);
                    names.add (info.get_name ());
                }
            }

            foreach (var info in infos) {
                var name = info.get_name ();
                if (info.get_is_hidden () || info.get_is_backup () || !is_shown_name (name)) {
                    continue;
                }
                // Firefox creates the final name empty next to name.part while it downloads.
                if (info.get_size () == 0 && names.contains (name + ".part")) {
                    continue;
                }
                result.add (StackEntry.from_file_info (dir.get_child (name), info));
            }
```

At the end of `reload ()`, just before `loaded ();`, add `update_refresh ();`, and add these methods:

```vala
    private bool has_downloads () {
        for (uint i = 0; i < store.get_n_items (); i++) {
            if (((StackEntry) store.get_item (i)).downloading) {
                return true;
            }
        }
        return false;
    }

    /* Runs refresh_downloads once a second while there is anything to refresh. */
    private void update_refresh () {
        if (has_downloads () && refresh_id == 0) {
            refresh_id = Timeout.add_seconds (1, on_refresh_tick);
        } else if (!has_downloads () && refresh_id != 0) {
            Source.remove (refresh_id);
            refresh_id = 0;
        }
    }

    private bool on_refresh_tick () {
        refresh_downloads.begin ();
        return Source.CONTINUE;
    }

    private async void refresh_downloads () {
        var now = get_real_time ();
        for (uint i = 0; i < store.get_n_items (); i++) {
            var entry = (StackEntry) store.get_item (i);
            if (!entry.downloading) {
                continue;
            }
            try {
                var info = yield entry.file.query_info_async (REFRESH_ATTRIBUTES, NONE, Priority.DEFAULT, cancellable);
                var modified = (int64) info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED) * 1000000
                    + info.get_attribute_uint32 (FileAttribute.TIME_MODIFIED_USEC);
                entry.update_download (info.get_size (), modified, now);
            } catch (Error e) {
                // Renamed on completion or cancelled: the next reload handles it.
            }
        }
    }
```

In `stop ()`, after removing `reload_id`, add:

```vala
        if (refresh_id != 0) {
            Source.remove (refresh_id);
            refresh_id = 0;
        }
```

- [ ] **Step 5: Run the tests to verify they pass**

Dock build. Expected: all tests pass. If `/stack-source/folder-date-added` fails on ordering, check `time::created` support in the build sandbox's `/tmp` before touching the code; the 20 ms spacing should rule out ties either way.

- [ ] **Step 6: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src
git commit -m "feat(modules): list downloads in progress in dock folder stacks"
```

---

### Task 5: Busy rows in the fan

**Files:**
- Modify: `stacks/src/FanPopover.vala`

**Interfaces:**
- Consumes: `StackBusy.bind`, `StackBusy.new_bar_revealer`, `StackProgressBar` (Task 3); download state (Task 4).

The grid already shows busy cells through `GridCell` (Task 3). This task does the same for the fan. The status sits in the label pill on the same line as the name, so row height (`FanMath.ROW_HEIGHT`) is unchanged.

- [ ] **Step 1: Generalise create_row_box**

Replace `create_row_box` with:

```vala
    // Label pill on the left, icon on the right, in an icon-wide slot so every
    // row's icon lands in the same column. The icon is the row's last child:
    // row_icon () relies on it.
    private static Gtk.Box create_row_box (Gtk.Widget pill, Gtk.Widget icon) {
        pill.add_css_class ("stack-fan-label");
        pill.valign = CENTER;

        icon.width_request = FanLayout.ICON_SIZE;
        icon.halign = CENTER;
        icon.valign = CENTER;

        var box = new Gtk.Box (HORIZONTAL, 8);
        box.append (pill);
        box.append (icon);
        return box;
    }

    private static Gtk.Image new_row_image (Icon? icon, int size) {
        var image = new Gtk.Image () { pixel_size = size, gicon = icon };
        image.add_css_class ("stack-icon");
        return image;
    }
```

Update the two other callers in `construct`:

```vala
        header = new Gtk.Button () {
            child = create_row_box (header_label, new_row_image (source.folder_icon (), HEADER_ICON_SIZE))
        };
```

```vala
        message = create_row_box (message_label, new_row_image (null, FanLayout.ICON_SIZE));
```

- [ ] **Step 2: Busy state in create_row**

Replace `create_row`'s widget construction (everything before `button.add_css_class ("stack-fan-item");`) with:

```vala
        var label = new Gtk.Label (entry.name) {
            ellipsize = MIDDLE,
            max_width_chars = 28
        };
        var status = new Gtk.Label (null);
        status.add_css_class ("stack-status");
        var pill = new Gtk.Box (HORIZONTAL, 8);
        pill.append (label);
        pill.append (status);

        var image = new_row_image (entry.icon, FanLayout.ICON_SIZE);
        StackProgressBar bar;
        var bar_revealer = StackBusy.new_bar_revealer (out bar);
        var icon = new Gtk.Overlay () { child = image };
        icon.add_overlay (bar_revealer);

        // The bindings die with the row; nothing needs to unbind them.
        StackBusy.bind (entry, image, status, bar_revealer, bar, new GenericArray<Binding> ());

        var button = new Gtk.Button () {
            child = create_row_box (pill, icon),
            tooltip_text = entry.name
        };
```

`StackEntry.launch ()` already opens the folder for a download (Task 4), so the click handler is unchanged.

- [ ] **Step 3: Build and look**

Dock build, then make a slow download and capture the fan:

```bash
( for i in $(seq 1 60); do head -c 200000 /dev/urandom >> ~/Downloads/progress-test.iso.part; sleep 1; done; rm -f ~/Downloads/progress-test.iso.part ) &
just pantheon::dock-run "$S/dock.log" DOCK_STACKS_OPEN=0
just pantheon::shot "$S/fan-download.png" 1000 300 1500 1140
```

Read the PNG. Expected: the newest row reads `progress-test.iso  Downloading · 1.2 MB` (size grows between captures), its icon dimmed with a pulsing bar along its bottom; rows the same height as the others. Take a second capture a few seconds later and confirm the size changed. Check the log for criticals. The background loop removes the file after a minute.

- [ ] **Step 4: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src/FanPopover.vala
git commit -m "feat(modules): show download status in the dock fan"
```

---

### Task 6: LauncherEntry feed and the tile progress bar

**Files:**
- Create: `stacks/src/LauncherProgress.vala`
- Modify: `stacks/src/StackSource.vala`, `stacks/src/StackItem.vala`, `stacks/src/StackStore.vala`, `stacks/src/meson.build`
- Test: `stacks/src/tests/StackTests.vala`

**Interfaces:**
- Consumes: download state (Task 4), `StackProgressBar`, `StackBusy.new_bar_revealer` (Task 3).
- Produces:
  - `Dock.LauncherProgress`: `static unowned LauncherProgress get_default ()`, public constructor (tests), `signal changed ()`, `void start ()`, `void update (string app_id, double? progress, bool? visible)`, `void handle_update (Variant parameters)`, `double download_fraction ()` (< 0 if none), `static bool is_browser (string app_id)`.
  - `StackSource.tile_busy : bool`, `StackSource.tile_progress : double` (< 0 pulses), both read-only, notifying on change; `private void update_tile ()`.

- [ ] **Step 1: Write the failing tests**

```vala
void test_launcher_progress () {
    var progress = new LauncherProgress ();
    assert_true (LauncherProgress.is_browser ("web.desktop"));
    assert_false (LauncherProgress.is_browser ("a.desktop"));
    assert_false (LauncherProgress.is_browser ("missing.desktop"));

    assert_true (progress.download_fraction () < 0);
    progress.handle_update (new Variant.parsed ("('application://web.desktop', {'progress': <0.25>, 'progress-visible': <true>})"));
    assert_near (progress.download_fraction (), 0.25);
    // Not a browser: ignored.
    progress.update ("a.desktop", 0.9, true);
    assert_near (progress.download_fraction (), 0.25);
    // A partial update keeps the other key.
    progress.update ("web.desktop", 0.5, null);
    assert_near (progress.download_fraction (), 0.5);
    progress.update ("web.desktop", null, false);
    assert_true (progress.download_fraction () < 0);
    // Malformed: ignored without a crash.
    progress.handle_update (new Variant.parsed ("('nope',)"));
}

void test_downloads_tile () {
    try {
        var dir = DirUtils.make_tmp ("stacks-XXXXXX");
        make_file (dir, "done.zip");
        var source = new StackSource (new StackConfig (dir, FAN, DATE_ADDED, STACK));
        wait_for_load (source);
        assert_false (source.tile_busy);

        make_file (dir, "video.mp4.crdownload");
        wait_for_load (source);
        assert_true (source.tile_busy);
        assert_true (source.tile_progress < 0);

        // Chromium's LauncherEntry fraction, only because a .crdownload is present.
        LauncherProgress.get_default ().update ("web.desktop", 0.5, true);
        assert_near (source.tile_progress, 0.5);
        LauncherProgress.get_default ().update ("web.desktop", null, false);
        assert_true (source.tile_progress < 0);

        // A stalled download is not busy.
        var old = get_real_time () / 1000000 - 120;
        File.new_for_path (Path.build_filename (dir, "stale.iso.part")).replace_contents ("x".data, null, false, NONE, null);
        File.new_for_path (Path.build_filename (dir, "stale.iso.part")).set_attribute_uint64 (FileAttribute.TIME_MODIFIED, old, NONE);
        FileUtils.remove (Path.build_filename (dir, "video.mp4.crdownload"));
        wait_for_load (source);
        assert_false (source.tile_busy);
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}
```

`assert_near` is defined further down the file; move it above `test_launcher_progress` (just after `find_entry`) so both can use it. Register:

```vala
    Test.add_func ("/launcher-progress/feed", test_launcher_progress);
    Test.add_func ("/stack-source/downloads-tile", test_downloads_tile);
```

- [ ] **Step 2: Run them to verify they fail**

Dock build. Expected: FAIL at compile time (`LauncherProgress`, `tile_busy` do not exist).

- [ ] **Step 3: Create LauncherProgress.vala**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Unity LauncherEntry progress, for the Downloads tile. Chromium browsers
 * (Chrome, Brave, Vivaldi) report download progress this way; Firefox and Zen
 * report it nowhere, so their downloads only pulse. Upstream AppSystem listens
 * to the same signal for its launchers; this subscription is independent.
 */

public class Dock.LauncherProgress : Object {
    private class State {
        public double progress = 0;
        public bool visible = false;
    }

    private static LauncherProgress? instance;
    public static unowned LauncherProgress get_default () {
        if (instance == null) {
            instance = new LauncherProgress ();
        }
        return instance;
    }

    public signal void changed ();

    private HashTable<string, State> states = new HashTable<string, State> (str_hash, str_equal);
    private bool started = false;

    /* Subscribes on the session bus. Idempotent; the unit tests never call it. */
    public void start () {
        if (started) {
            return;
        }
        started = true;
        Bus.get.begin (BusType.SESSION, null, on_bus);
    }

    private void on_bus (Object? obj, AsyncResult res) {
        try {
            var connection = Bus.get.end (res);
            connection.signal_subscribe (
                null, "com.canonical.Unity.LauncherEntry", "Update", null, null,
                DBusSignalFlags.NONE, on_signal
            );
        } catch (Error e) {
            warning ("No session bus for LauncherEntry progress: %s", e.message);
        }
    }

    private void on_signal (DBusConnection connection, string? sender, string path, string iface,
                            string signal_name, Variant parameters) {
        handle_update (parameters);
    }

    /* parameters: (sa{sv}), an application:// URI and the changed properties. */
    public void handle_update (Variant parameters) {
        if (!parameters.is_of_type (new VariantType ("(sa{sv})"))) {
            return;
        }
        string uri;
        VariantIter props;
        parameters.get ("(sa{sv})", out uri, out props);

        double? progress = null;
        bool? visible = null;
        string key;
        Variant value;
        while (props.next ("{sv}", out key, out value)) {
            if (key == "progress" && value.is_of_type (VariantType.DOUBLE)) {
                progress = value.get_double ();
            } else if (key == "progress-visible" && value.is_of_type (VariantType.BOOLEAN)) {
                visible = value.get_boolean ();
            }
        }
        update (uri.replace ("application://", ""), progress, visible);
    }

    /* A null argument leaves that property as it was: updates are partial. */
    public void update (string app_id, double? progress, bool? visible) {
        if (progress == null && visible == null) {
            return;
        }
        var state = states[app_id];
        if (state == null) {
            state = new State ();
            states[app_id] = state;
        }
        if (progress != null) {
            state.progress = progress;
        }
        if (visible != null) {
            state.visible = visible;
        }
        changed ();
    }

    /* The mean progress of every browser showing progress, or -1 if none is. */
    public double download_fraction () {
        double sum = 0;
        uint count = 0;
        states.foreach ((app_id, state) => {
            if (state.visible && is_browser (app_id)) {
                sum += state.progress;
                count++;
            }
        });
        return count == 0 ? -1 : sum / count;
    }

    public static bool is_browser (string app_id) {
        var info = new DesktopAppInfo (app_id);
        if (info == null) {
            return false;
        }
        return "x-scheme-handler/https" in (info.get_string ("MimeType") ?? "").split (";");
    }
}
```

Add `'LauncherProgress.vala',` to `stacks_core_sources`; `git add -N` it.

- [ ] **Step 4: Tile state in StackSource**

Add properties:

```vala
    /* The tile shows a progress bar while this is true. */
    public bool tile_busy { get; private set; default = false; }
    /* 0–1, or below 0 to pulse. */
    public double tile_progress { get; private set; default = -1; }
```

In `construct`, in the `else` branch (folder sources), after the monitor is set up:

```vala
            LauncherProgress.get_default ().changed.connect (update_tile);
```

In `stop ()`, at the top after the debug line:

```vala
        LauncherProgress.get_default ().changed.disconnect (update_tile);
```

At the end of `reload ()` (before `update_refresh ();`) and at the end of `refresh_downloads ()`, call `update_tile ();`. Add:

```vala
    private void update_tile () {
        bool busy = false;
        bool chromium = false;
        for (uint i = 0; i < store.get_n_items (); i++) {
            var entry = (StackEntry) store.get_item (i);
            if (entry.downloading && !entry.stalled) {
                busy = true;
                chromium = chromium || entry.file.get_basename ().has_suffix (".crdownload");
            }
        }
        set_tile (busy, chromium ? LauncherProgress.get_default ().download_fraction () : -1);
    }

    // Only on change: the tile bar is re-laid-out on every notify.
    private void set_tile (bool busy, double progress) {
        if (tile_busy != busy) {
            tile_busy = busy;
        }
        if (tile_progress != progress) {
            tile_progress = progress;
        }
    }
```

- [ ] **Step 5: Start the feed in the dock**

In `StackStore.vala` `construct`, first line:

```vala
        // The feeds the stacks' progress comes from; started here, never in unit tests.
        LauncherProgress.get_default ().start ();
```

- [ ] **Step 6: The tile bar in StackItem**

Fields:

```vala
    private Gtk.Revealer progress_revealer;
```

In `construct`, after the `bounce_up.done.connect` line:

```vala
        progress_revealer = new Gtk.Revealer () {
            can_target = false,
            transition_type = CROSSFADE,
            valign = END
        };
        overlay.add_overlay (progress_revealer);
        progress_revealer.notify["child-revealed"].connect (on_progress_child_revealed);
        source.notify["tile-busy"].connect (update_progress);
        update_progress ();
```

Methods:

```vala
    // As upstream Launcher does: build the bar when it is shown and drop it once
    // hidden, so an idle tile has no bar asking for layout (elementary/dock#279).
    private void update_progress () {
        progress_revealer.reveal_child = source.tile_busy;
        if (source.tile_busy && progress_revealer.child == null) {
            var bar = new StackProgressBar ();
            source.bind_property ("tile-progress", bar, "fraction", SYNC_CREATE);
            progress_revealer.child = bar;
        }
    }

    private void on_progress_child_revealed () {
        if (!progress_revealer.child_revealed) {
            progress_revealer.child = null;
        }
    }
```

In `teardown ()`, next to the other `source.notify` disconnects:

```vala
        source.notify["tile-busy"].disconnect (update_progress);
```

- [ ] **Step 7: Run the tests to verify they pass**

Dock build. Expected: all tests pass.

- [ ] **Step 8: Look at both tile states**

```bash
( for i in $(seq 1 60); do head -c 200000 /dev/urandom >> ~/Downloads/progress-test.crdownload; sleep 1; done; rm -f ~/Downloads/progress-test.crdownload ) &
just pantheon::dock-run "$S/dock.log"
just pantheon::shot "$S/tile-pulse.png" 1500 1240 600 200
gdbus emit --session --object-path /test --signal com.canonical.Unity.LauncherEntry.Update \
  "application://com.google.Chrome.desktop" "{'progress': <0.4>, 'progress-visible': <true>}"
just pantheon::shot "$S/tile-fraction.png" 1500 1240 600 200
gdbus emit --session --object-path /test --signal com.canonical.Unity.LauncherEntry.Update \
  "application://com.google.Chrome.desktop" "{'progress-visible': <false>}"
```

Read both. Expected: a thin bar along the bottom of the Downloads tile, pulsing in the first, 40 % filled in the second. The upstream dock may log `unable to update missing launcher: com.google.Chrome.desktop` when Chrome is not pinned; that is upstream's line and expected. Wait until the background loop finishes (≈ 60 s) and confirm with one more capture that the bar is gone.

- [ ] **Step 9: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src
git commit -m "feat(modules): show download progress on the dock Downloads tile"
```

---

### Task 7: AppCenter publishes its jobs

**Files:**
- Create: `modules/constellation/pantheon-dock/appcenter/progress.patch`
- Modify: `modules/constellation/pantheon-dock/default.nix`

**Interfaces:**
- Produces, on the session bus (`io.elementary.appcenter`, object `/io/elementary/appcenter`, interface `io.elementary.appcenter`): signal `JobChanged (ssssud)`, method `GetJobs () → a(ssssud)`. Field order `component_id, desktop_id, name, icon, state, progress`; `state` 0 idle/finished, 1 installing, 2 updating, 3 removing.

Already checked against the source: `UpdateManager.update_all ()` (automatic and "Update All") calls `Package.update ()` per package, and every install, update and remove goes through `Package.perform_operation`. The combined runtime job is the package with id `xxx-runtime-updates`; it has no desktop-id launchable, so it publishes an empty `desktop_id`. Progress is `ChangeInformation.progress`, 0–1.

- [ ] **Step 1: Check out the source to patch**

```bash
cd /home/arosenfeld/Code/nixos
W=/tmp/claude-1000/-home-arosenfeld-Code-nixos/appcenter-src && rm -rf "$W" && mkdir -p "$W"
src=$(nix build --no-link --print-out-paths --impure --expr '(builtins.getFlake (toString ./.)).nixosConfigurations.raider.pkgs.pantheon.appcenter.src')
cp -r "$src"/. "$W" && chmod -R u+w "$W"
git -C "$W" init -q && git -C "$W" add -A && git -C "$W" -c user.name=x -c user.email=x commit -qm base
```

- [ ] **Step 2: Add `src/Core/JobTracker.vala`**

```vala
/*
 * Every install, update and removal in progress, for the dock: DBusServer
 * publishes them as JobChanged and GetJobs. A local patch from the NixOS
 * config (modules/constellation/pantheon-dock/appcenter), not upstream.
 */
public class AppCenterCore.JobTracker : Object {
    // 4 Hz: enough for a progress bar, little enough for the session bus.
    private const int64 MIN_INTERVAL_USEC = 250000;

    private static GLib.Once<JobTracker> instance;
    public static unowned JobTracker get_default () {
        return instance.once (() => { return new JobTracker (); });
    }

    public signal void changed (Package package);

    private Gee.HashMap<Package, ulong> handlers = new Gee.HashMap<Package, ulong> ();
    private Gee.HashMap<Package, int64?> last_emit = new Gee.HashMap<Package, int64?> ();

    public Gee.Collection<Package> running { owned get { return handlers.keys.read_only_view; } }

    public bool is_running (Package package) {
        return handlers.has_key (package);
    }

    public void begin (Package package) {
        if (handlers.has_key (package)) {
            return;
        }
        handlers[package] = package.change_information.notify["progress"].connect (() => on_progress (package));
        last_emit[package] = 0;
        changed (package);
    }

    public void end (Package package) {
        ulong id;
        if (handlers.unset (package, out id)) {
            package.change_information.disconnect (id);
        }
        last_emit.unset (package);
        changed (package);
    }

    private void on_progress (Package package) {
        var now = get_monotonic_time ();
        if (now - last_emit[package] < MIN_INTERVAL_USEC) {
            return;
        }
        last_emit[package] = now;
        changed (package);
    }
}
```

Add `'Core/JobTracker.vala',` to `$W/src/meson.build` right after `'Core/Job.vala',`.

- [ ] **Step 3: Hook `Package.perform_operation`**

In `$W/src/Core/Package.vala`, `perform_operation` becomes:

```vala
    private async void perform_operation (State performing) throws GLib.Error {
        change_information.start ();
        state = performing;
        JobTracker.get_default ().begin (this);

        backend.notify_package_changed (this);

        try {
            yield perform_package_operation ();
            backend.operation_finished (this, performing, null);
        } catch (GLib.Error e) {
            warning ("Operation failed for package %s - %s", name, e.message);
            backend.operation_finished (this, performing, e);
            throw e;
        } finally {
            change_information.complete ();
            update_state ();
            JobTracker.get_default ().end (this);
        }
    }
```

- [ ] **Step 4: Publish from DBusServer**

In `$W/src/Services/DBusServer.vala`, before `[DBus (name="io.elementary.appcenter")]`:

```vala
/* One running job, as GetJobs returns it: (ssssud). */
public struct AppCenterJobInfo {
    public string component_id;
    public string desktop_id;
    public string name;
    public string icon;
    public uint state;
    public double progress;
}
```

Inside the class, after `get_default ()`:

```vala
    /**
     * An install, update or removal started, progressed or ended (state 0).
     * state: 0 idle/finished, 1 installing, 2 updating, 3 removing.
     */
    public signal void job_changed (string component_id, string desktop_id, string name, string icon, uint state, double progress);

    // If DBusServer already has a construct block, add this line to it instead.
    construct {
        AppCenterCore.JobTracker.get_default ().changed.connect (on_job_changed);
    }

    /**
     * Every job running now, for a client that started mid-job.
     */
    public AppCenterJobInfo[] get_jobs () throws Error {
        AppCenterJobInfo[] jobs = {};
        foreach (var package in AppCenterCore.JobTracker.get_default ().running) {
            jobs += job_info (package);
        }
        return jobs;
    }

    private void on_job_changed (AppCenterCore.Package package) {
        var job = job_info (package);
        job_changed (job.component_id, job.desktop_id, job.name, job.icon, job.state, job.progress);
    }

    private static AppCenterJobInfo job_info (AppCenterCore.Package package) {
        uint state = 0;
        if (AppCenterCore.JobTracker.get_default ().is_running (package)) {
            switch (package.state) {
                case INSTALLING: state = 1; break;
                case UPDATING: state = 2; break;
                case REMOVING: state = 3; break;
                default: break;
            }
        }

        var desktop_id = "";
        var launchable = package.component.get_launchable (AppStream.LaunchableKind.DESKTOP_ID);
        if (launchable != null && launchable.get_entries ().length > 0) {
            desktop_id = launchable.get_entries ()[0];
        }

        return AppCenterJobInfo () {
            component_id = package.component.get_id (),
            desktop_id = desktop_id,
            name = package.name,
            icon = package.get_icon (64, 1).to_string () ?? "",
            state = state,
            progress = package.change_information.progress
        };
    }
```

- [ ] **Step 5: Write the patch**

```bash
git -C "$W" add -A
git -C "$W" diff --cached > /home/arosenfeld/Code/nixos/modules/constellation/pantheon-dock/appcenter/progress.patch
cd /home/arosenfeld/Code/nixos && git add -N modules/constellation/pantheon-dock/appcenter/progress.patch
```

(Create the `appcenter/` directory first if `git diff` complains it is missing: `mkdir -p modules/constellation/pantheon-dock/appcenter`.)

- [ ] **Step 6: Apply it in the overlay**

In `default.nix`, inside `pantheon.overrideScope (pfinal: pprev: { … })`, after the `elementary-dock = …;` attribute:

```nix
          # appcenter/: publishes AppCenter's install/update/remove jobs on its D-Bus
          # object (JobChanged, GetJobs), for the Applications stack's progress.
          # Design: docs/superpowers/specs/2026-10-31-dock-stacks-progress-design.md
          appcenter = pprev.appcenter.overrideAttrs (old: {
            patches = (old.patches or []) ++ [./appcenter/progress.patch];
          });
```

Extend the comment block at the top of the file with one paragraph:

```nix
# appcenter/progress.patch is the one patch here that is not the dock's: it makes
# AppCenter publish its jobs, which the Applications stack shows as progress.
# A nixpkgs bump of appcenter that breaks it is rebased the same way.
```

Run `just fmt`.

- [ ] **Step 7: Build and check the D-Bus surface**

```bash
appcenter=$(nix build --no-link --print-out-paths .#nixosConfigurations.raider.pkgs.pantheon.appcenter)
nix build --no-link .#nixosConfigurations.raider.config.system.build.toplevel
nix path-info -r $(nix build --no-link --print-out-paths .#nixosConfigurations.raider.config.system.build.toplevel) | grep -F "$appcenter"
```

Expected: both builds succeed and the last command prints the patched store path, which shows that the system uses this AppCenter.

Then swap the running AppCenter daemon for the patched one and look at it:

```bash
pkill -f 'io.elementary.appcenter --silent' ; ( "$appcenter/bin/io.elementary.appcenter" --silent >"$S/appcenter.log" 2>&1 & ) ; sleep 3
gdbus introspect --session --dest io.elementary.appcenter --object-path /io/elementary/appcenter | grep -E 'GetJobs|JobChanged'
gdbus call --session --dest io.elementary.appcenter --object-path /io/elementary/appcenter --method io.elementary.appcenter.GetJobs
```

Expected: the introspection lists `GetJobs` and `JobChanged`, and the call returns `(@a(ssssud) [],)`. Leave the patched daemon running for Task 8's end-to-end check. The next login brings back the system's daemon either way.

- [ ] **Step 8: Commit**

```bash
git add modules/constellation/pantheon-dock/default.nix modules/constellation/pantheon-dock/appcenter/progress.patch
git commit -m "feat(modules): publish AppCenter install and update jobs over D-Bus"
```

---

### Task 8: AppCenter jobs on the Applications stack

**Files:**
- Create: `stacks/src/AppCenterJobs.vala`
- Modify: `stacks/src/StackEntry.vala`, `stacks/src/StackSource.vala`, `stacks/src/StackStore.vala`, `stacks/src/meson.build`
- Test: `stacks/src/tests/StackTests.vala`

**Interfaces:**
- Consumes: the D-Bus surface (Task 7); `tile_busy`/`tile_progress`/`set_tile` (Task 6); busy state (Task 3); folders (Task 2).
- Produces:
  - `Dock.AppCenterJobs`: `enum State { IDLE, INSTALLING, UPDATING, REMOVING }`; nested `class Job : Object` with fields `component_id, desktop_id, name, icon : string`, `state : State`, `progress : double`, `string status_text ()`, `static Job? from_variant (Variant v)`; `static unowned AppCenterJobs get_default ()`, public constructor; `signal changed (Job job)`; `uint count`; `GenericArray<Job> get_all ()`; `Job? for_desktop_id (string id)`; `double mean_progress ()`; `void apply (Job job)`; `void clear ()`; `void start ()`.
  - `StackEntry.job_component_id : string?`; `static StackEntry StackEntry.provisional (AppCenterJobs.Job job)`.

- [ ] **Step 1: Write the failing tests**

```vala
AppCenterJobs.Job make_job (string desktop_id, AppCenterJobs.State state, double progress) {
    return new AppCenterJobs.Job ("comp." + desktop_id, desktop_id, "Newapp", "", state, progress);
}

void test_job_parsing () {
    var job = AppCenterJobs.Job.from_variant (new Variant.parsed ("('org.x', 'org.x.desktop', 'X', '', uint32 1, 0.5)"));
    assert_nonnull (job);
    assert_cmpstr (job.desktop_id, EQ, "org.x.desktop");
    assert_true (job.state == AppCenterJobs.State.INSTALLING);
    assert_cmpstr (job.status_text (), EQ, "Installing");

    Test.expect_message (null, LogLevelFlags.LEVEL_WARNING, "*Ignoring malformed AppCenter job*");
    assert_null (AppCenterJobs.Job.from_variant (new Variant.parsed ("('org.x',)")));
    Test.assert_expected_messages ();
}

void test_jobs_store () {
    var jobs = new AppCenterJobs ();
    jobs.apply (make_job ("a.desktop", UPDATING, 0.2));
    jobs.apply (make_job ("b.desktop", INSTALLING, 0.6));
    assert_cmpuint (jobs.count, EQ, 2);
    assert_near (jobs.mean_progress (), 0.4);
    jobs.apply (make_job ("a.desktop", IDLE, 1));
    assert_cmpuint (jobs.count, EQ, 1);
    assert_null (jobs.for_desktop_id ("a.desktop"));
    jobs.clear ();
    assert_cmpuint (jobs.count, EQ, 0);
}

void test_applications_jobs () {
    var jobs = AppCenterJobs.get_default ();
    var source = new StackSource (new StackConfig (StackConfig.APPLICATIONS, GRID, NAME, STACK));
    wait_for_load (source);

    // A new install: a provisional cell first at the top level.
    jobs.apply (make_job ("new.desktop", INSTALLING, 0.3));
    wait_for_load (source);
    var first = (StackEntry) source.entries.get_item (0);
    assert_cmpstr (first.name, EQ, "Newapp");
    assert_cmpstr (first.status_text, EQ, "Installing");
    assert_near (first.progress, 0.3);
    assert_cmpstr (first.job_component_id, EQ, "comp.new.desktop");
    assert_true (source.tile_busy);
    assert_near (source.tile_progress, 0.3);

    // An update of an app inside a folder: the cell and the folder both show it.
    jobs.apply (make_job ("calc.desktop", UPDATING, 0.5));
    var utilities = find_entry (source.entries, "Utilities");
    var calc = find_entry (utilities.children, "Calc");
    assert_cmpstr (calc.status_text, EQ, "Updating");
    assert_true (utilities.show_progress);
    assert_near (utilities.progress, 0.5);
    assert_near (source.tile_progress, 0.4);

    jobs.apply (make_job ("calc.desktop", IDLE, 1));
    assert_null (calc.status_text);
    assert_null (calc.job_component_id);
    assert_false (utilities.show_progress);

    jobs.apply (make_job ("new.desktop", IDLE, 1));
    wait_for_load (source);
    assert_null (find_entry (source.entries, "Newapp"));
    assert_false (source.tile_busy);
}
```

Register:

```vala
    Test.add_func ("/appcenter-jobs/parse", test_job_parsing);
    Test.add_func ("/appcenter-jobs/store", test_jobs_store);
    Test.add_func ("/stack-source/applications-jobs", test_applications_jobs);
```

- [ ] **Step 2: Run them to verify they fail**

Dock build. Expected: FAIL at compile time (`AppCenterJobs` does not exist).

- [ ] **Step 3: Create AppCenterJobs.vala**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * AppCenter's installs, updates and removals in progress, from the
 * JobChanged signal and GetJobs method that the local AppCenter patch adds
 * (modules/constellation/pantheon-dock/appcenter/progress.patch). Plain
 * GDBus rather than a proxy interface, so upstream's AppCenterDBus stays
 * untouched and a malformed message can be rejected instead of crashing.
 */

public class Dock.AppCenterJobs : Object {
    private const string NAME = "io.elementary.appcenter";
    private const string PATH = "/io/elementary/appcenter";
    private const string IFACE = "io.elementary.appcenter";
    private const string JOB_TYPE = "(ssssud)";

    public enum State { IDLE, INSTALLING, UPDATING, REMOVING }

    public class Job : Object {
        public string component_id;
        public string desktop_id;
        public string name;
        public string icon;
        public State state;
        public double progress;

        public Job (string component_id, string desktop_id, string name, string icon, State state, double progress) {
            this.component_id = component_id;
            this.desktop_id = desktop_id;
            this.name = name;
            this.icon = icon;
            this.state = state;
            this.progress = progress;
        }

        public string status_text () {
            switch (state) {
                case INSTALLING: return _("Installing");
                case UPDATING: return _("Updating");
                case REMOVING: return _("Removing");
                default: return "";
            }
        }

        public static Job? from_variant (Variant value) {
            if (!value.is_of_type (new VariantType (JOB_TYPE))) {
                warning ("Ignoring malformed AppCenter job: %s", value.print (true));
                return null;
            }
            string component_id, desktop_id, name, icon;
            uint state;
            double progress;
            value.get (JOB_TYPE, out component_id, out desktop_id, out name, out icon, out state, out progress);
            if (state > State.REMOVING) {
                warning ("Ignoring malformed AppCenter job: state %u", state);
                return null;
            }
            return new Job (component_id, desktop_id, name, icon, (State) state, progress);
        }
    }

    private static AppCenterJobs? instance;
    public static unowned AppCenterJobs get_default () {
        if (instance == null) {
            instance = new AppCenterJobs ();
        }
        return instance;
    }

    /* A job started, moved or ended (state IDLE). */
    public signal void changed (Job job);

    public uint count { get { return jobs.size (); } }

    // By component id: a runtime update has no desktop id.
    private HashTable<string, Job> jobs = new HashTable<string, Job> (str_hash, str_equal);
    private bool started = false;
    private DBusConnection? connection;
    private uint subscription = 0;

    public GenericArray<Job> get_all () {
        var all = new GenericArray<Job> ();
        jobs.foreach ((id, job) => all.add (job));
        return all;
    }

    public Job? for_desktop_id (string desktop_id) {
        return jobs.find ((id, job) => job.desktop_id == desktop_id);
    }

    public double mean_progress () {
        if (jobs.size () == 0) {
            return -1;
        }
        double sum = 0;
        jobs.foreach ((id, job) => sum += job.progress);
        return sum / jobs.size ();
    }

    public void apply (Job job) {
        if (job.state == IDLE) {
            jobs.remove (job.component_id);
        } else {
            jobs[job.component_id] = job;
        }
        changed (job);
    }

    /* Ends every job: AppCenter went away mid-job, and nothing else will. */
    public void clear () {
        foreach (var job in get_all ()) {
            apply (new Job (job.component_id, job.desktop_id, job.name, job.icon, IDLE, 1));
        }
    }

    /* Follows AppCenter on the session bus. Idempotent; the unit tests never call it. */
    public void start () {
        if (started) {
            return;
        }
        started = true;
        start_fake_job ();
        // No AUTO_START: AppCenter's own --silent daemon is already running in a
        // Pantheon session, and the dock must not be what starts it.
        Bus.watch_name (BusType.SESSION, NAME, BusNameWatcherFlags.NONE, on_appeared, on_vanished);
    }

    private void on_appeared (DBusConnection connection, string name, string owner) {
        this.connection = connection;
        // Matched on the unique name: GDBus compares a signal's sender to the
        // unique name the message carries, not to the well-known one.
        subscription = connection.signal_subscribe (owner, IFACE, "JobChanged", PATH, null, NONE, on_job_signal);
        connection.call.begin (owner, PATH, IFACE, "GetJobs", null, new VariantType ("(a" + JOB_TYPE + ")"),
                               NONE, -1, null, on_get_jobs);
    }

    private void on_get_jobs (Object? obj, AsyncResult res) {
        try {
            var reply = ((DBusConnection) obj).call.end (res);
            var list = reply.get_child_value (0);
            for (size_t i = 0; i < list.n_children (); i++) {
                var job = Job.from_variant (list.get_child_value (i));
                if (job != null) {
                    apply (job);
                }
            }
        } catch (Error e) {
            // An AppCenter without the local patch: no progress, nothing else changes.
            debug ("AppCenter has no GetJobs (%s); showing no app progress", e.message);
        }
    }

    private void on_vanished (DBusConnection? connection, string name) {
        if (this.connection != null && subscription != 0) {
            this.connection.signal_unsubscribe (subscription);
        }
        subscription = 0;
        this.connection = null;
        clear ();
    }

    private void on_job_signal (DBusConnection connection, string? sender, string path, string iface,
                                string signal_name, Variant parameters) {
        var job = Job.from_variant (parameters);
        if (job != null) {
            apply (job);
        }
    }

    // Test hook: DOCK_STACKS_FAKE_JOB=<desktop-id>:<state>:<progress> injects one
    // job at startup, without AppCenter. An unknown desktop id is a new install.
    private void start_fake_job () {
        var fake = Environment.get_variable ("DOCK_STACKS_FAKE_JOB");
        if (fake == null) {
            return;
        }
        var parts = fake.split (":");
        if (parts.length != 3) {
            warning ("DOCK_STACKS_FAKE_JOB: expected <desktop-id>:<state>:<progress>, got '%s'", fake);
            return;
        }
        var name = parts[0].has_suffix (".desktop") ? parts[0].substring (0, parts[0].length - 8) : parts[0];
        apply (new Job ("fake." + parts[0], parts[0], name, "", (State) int.parse (parts[1]), double.parse (parts[2])));
    }
}
```

Add `'AppCenterJobs.vala',` to `stacks_core_sources`; `git add -N` it.

- [ ] **Step 4: Provisional entries and the job link on StackEntry**

In `StackEntry.vala`, after `stalled`:

```vala
    /* The AppCenter component of the job running on this entry, while one runs. */
    public string? job_component_id { get; set; default = null; }
```

After `for_folder`:

```vala
    /* A cell for an app AppCenter is installing, before it has a desktop file. */
    public static StackEntry provisional (AppCenterJobs.Job job) {
        Icon? icon = null;
        if (job.icon != "") {
            try {
                icon = Icon.new_for_string (job.icon);
            } catch (Error e) {
                debug ("Bad icon from AppCenter for %s: %s", job.name, e.message);
            }
        }
        return new StackEntry (job.name, icon ?? new ThemedIcon ("application-default-icon"), null, null, 0);
    }
```

In `launch ()`, after the `is_folder` early return:

```vala
        if (job_component_id != null) {
            // Being installed, updated or removed: show it in AppCenter.
            open_uri ("appcenter://" + job_component_id);
            return;
        }
        if (app == null && file == null) {
            // A provisional cell whose install just ended; the pending reload replaces it.
            return;
        }
```

- [ ] **Step 5: Jobs in StackSource**

Fields:

```vala
    // Every app entry (and provisional one) by desktop id, for job updates.
    private HashTable<string, StackEntry> by_desktop_id = new HashTable<string, StackEntry> (str_hash, str_equal);
```

In `construct`, in the `if (config.is_applications)` branch:

```vala
            AppCenterJobs.get_default ().changed.connect (on_job_changed);
```

In `stop ()`, next to the LauncherProgress disconnect:

```vala
        AppCenterJobs.get_default ().changed.disconnect (on_job_changed);
```

In `reload ()`, right after the `loaded_entries.sort (...)` line, add the provisional entries and the index:

```vala
        by_desktop_id.remove_all ();
        Object[] provisional = {};
        if (config.is_applications) {
            foreach (var entry in loaded_entries) {
                by_desktop_id[entry.app.get_id ()] = entry;
            }
            foreach (var job in AppCenterJobs.get_default ().get_all ()) {
                if (job.state == INSTALLING && job.desktop_id != "" && !(job.desktop_id in by_desktop_id)) {
                    var entry = StackEntry.provisional (job);
                    by_desktop_id[job.desktop_id] = entry;
                    provisional += entry;
                }
            }
            by_desktop_id.foreach ((desktop_id, entry) => {
                apply_job (entry, AppCenterJobs.get_default ().for_desktop_id (desktop_id));
            });
        }
```

Then change the two places that start `items`/`previews` so provisional cells come first: replace `Object[] items = {};` and `Object[] previews = {};` with:

```vala
        Object[] items = provisional;
        Object[] previews = provisional;
```

After both splices, add `update_folder_progress ();`. Replace the whole `update_tile ()` method from Task 6 with this version. Its callers stay as they are:

```vala
    private void update_tile () {
        if (config.is_applications) {
            var jobs = AppCenterJobs.get_default ();
            set_tile (jobs.count > 0, jobs.mean_progress ());
            return;
        }

        bool busy = false;
        bool chromium = false;
        for (uint i = 0; i < store.get_n_items (); i++) {
            var entry = (StackEntry) store.get_item (i);
            if (entry.downloading && !entry.stalled) {
                busy = true;
                chromium = chromium || entry.file.get_basename ().has_suffix (".crdownload");
            }
        }
        set_tile (busy, chromium ? LauncherProgress.get_default ().download_fraction () : -1);
    }
```

Add:

```vala
    private static void apply_job (StackEntry entry, AppCenterJobs.Job? job) {
        if (job == null || job.state == IDLE) {
            entry.job_component_id = null;
            entry.status_text = null;
            entry.show_progress = false;
            return;
        }
        entry.job_component_id = job.component_id;
        entry.status_text = job.status_text ();
        entry.progress = job.progress;
        entry.show_progress = true;
    }

    /* A folder shows a bar while any of its apps is busy: their mean progress. */
    private void update_folder_progress () {
        for (uint i = 0; i < store.get_n_items (); i++) {
            var folder = (StackEntry) store.get_item (i);
            if (!folder.is_folder) {
                continue;
            }
            double sum = 0;
            uint busy = 0;
            for (uint j = 0; j < folder.children.get_n_items (); j++) {
                var child = (StackEntry) folder.children.get_item (j);
                if (child.show_progress) {
                    sum += child.progress;
                    busy++;
                }
            }
            folder.show_progress = busy > 0;
            folder.progress = busy > 0 ? sum / busy : -1;
        }
    }

    private void on_job_changed (AppCenterJobs.Job job) {
        var entry = job.desktop_id != "" ? by_desktop_id[job.desktop_id] : null;
        var is_provisional = entry != null && entry.app == null;
        if (entry == null && job.state == INSTALLING && job.desktop_id != "") {
            // A new install: the reload adds its provisional cell.
            queue_reload ();
        } else if (is_provisional && job.state == IDLE) {
            // Done: the reload drops the provisional cell. AppInfoMonitor also
            // reloads once the real desktop file appears.
            queue_reload ();
        } else if (entry != null) {
            apply_job (entry, job);
            update_folder_progress ();
        }
        update_tile ();
    }
```

- [ ] **Step 6: Start the feed in the dock**

In `StackStore.vala` `construct`, after `LauncherProgress.get_default ().start ();`:

```vala
        AppCenterJobs.get_default ().start ();
```

- [ ] **Step 7: Run the tests to verify they pass**

Dock build. Expected: all tests pass.

- [ ] **Step 8: Look at it with the fake hook**

```bash
just pantheon::dock-run "$S/dock.log" DOCK_STACKS_OPEN=1 DOCK_STACKS_FAKE_JOB=org.example.New.desktop:1:0.35
just pantheon::shot "$S/apps-install.png" 1000 300 1500 1140
just pantheon::shot "$S/apps-install-tile.png" 1500 1240 600 200
just pantheon::dock-run "$S/dock.log" DOCK_STACKS_OPEN=1 DOCK_STACKS_FOLDER=Utilities DOCK_STACKS_FAKE_JOB=org.gnome.Calculator.desktop:2:0.6
just pantheon::shot "$S/apps-update.png" 1000 300 1500 1140
```

Pick a desktop id for the second run that `AppFolders` puts in Utilities on raider. Check with `grep Categories $(find /run/current-system/sw/share/applications /var/lib/flatpak/exports/share/applications -name 'org.gnome.Calculator.desktop')`, and substitute another Utility app if Calculator isn't installed.

Expected: first capture shows a dimmed `org.example.New` cell first in the grid, with "Installing" and a 35 % bar; the tile shows a 35 % bar. Second capture shows the Utilities folder with the app dimmed, "Updating" and a 60 % bar.

- [ ] **Step 9: End to end with the real AppCenter (ask first)**

This installs and removes a real flatpak, and may raise a polkit prompt on the user's screen. **Ask the user before running it.** With the patched daemon from Task 7 still running and the dock from this task (`just pantheon::dock-run "$S/dock.log" DOCK_STACKS_OPEN=1`):

```bash
flatpak info org.gnome.Calculator >/dev/null 2>&1 && echo "already installed: pick another small app"
gdbus call --session --dest io.elementary.appcenter --object-path /io/elementary/appcenter --method io.elementary.appcenter.Install org.gnome.Calculator
sleep 3; just pantheon::shot "$S/apps-real-install.png" 1000 300 1500 1140
```

Expected: a provisional "Calculator" cell with a moving bar. When the install finishes, the cell becomes the real app inside Utilities. Then remove the app: `flatpak uninstall -y org.gnome.Calculator`.

- [ ] **Step 10: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src
git commit -m "feat(modules): show AppCenter installs and updates on the dock Applications stack"
```

---

### Task 9: Docs, VM test, deploy

**Files:**
- Modify: `modules/constellation/pantheon-dock/CLAUDE.md`

- [ ] **Step 1: Document the hooks and feeds**

In `CLAUDE.md`, in the "Never inject input" bullet, after the `DOCK_STACKS_CLICK` sentences, add:

```markdown
  `DOCK_STACKS_FOLDER=<folder name>`, with `DOCK_STACKS_OPEN` on the Applications grid, opens
  that folder (`Games`, `System`, `Utilities`, `Terminal Tools`).
  `DOCK_STACKS_FAKE_JOB=<desktop-id>:<state>:<progress>` injects one AppCenter job at start
  (state 1 installing, 2 updating, 3 removing); an id with no desktop file is a new install.
  Download progress needs no hook: append to `~/Downloads/<name>.part` slowly, and for a real
  fraction also have a `.crdownload` and `gdbus emit` a `com.canonical.Unity.LauncherEntry.Update`.
```

Add a new section before "## Vala pitfalls that bit here":

```markdown
## Where stack progress comes from

- **Downloads** come from the folder itself: partial files (`.part`, `.crdownload`,
  `.download`) are entries, refreshed once a second. Only Chromium browsers also send a
  fraction, as Unity LauncherEntry (`LauncherProgress.vala`); Zen and Firefox send nothing,
  so their downloads pulse.
- **Applications** progress comes from AppCenter, through a local patch
  (`appcenter/progress.patch`) that adds `JobChanged` and `GetJobs` to its D-Bus object
  (`AppCenterJobs.vala` reads them). Bazaar, nix-flatpak and the `flatpak` CLI publish
  nothing. An AppCenter without the patch (a session started before the deploy) just
  shows no progress.
- The AppCenter daemon (`io.elementary.appcenter --silent`) keeps running the old binary
  until the next login, like the dock's schema.
```

- [ ] **Step 2: Run the VM test**

```bash
nix build --no-link -L .#checks.x86_64-linux.pantheon-dock-test 2>&1 | tail -n 40
```

Expected: PASS. In particular, the dock still starts with both stacks and the journal has no criticals.

- [ ] **Step 3: Build the hosts**

```bash
just build raider
just build blackbird
```

Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add modules/constellation/pantheon-dock/CLAUDE.md
git commit -m "docs(modules): document dock stack progress feeds and hooks"
```

- [ ] **Step 5: Hand over the deploy**

Don't deploy on your own. Tell the user the work is ready for `just deploy raider` (and blackbird). After a re-login, they should open the Applications stack, download a file, and let AppCenter update something. Before the session ends, return the live session to the stock dock (`pkill -f '(^|/)io\.elementary\.dock$'`) and the stock AppCenter (`pkill -f 'io.elementary.appcenter --silent'`, then log out and back in, or start `/run/current-system/sw/bin/io.elementary.appcenter --silent`).
