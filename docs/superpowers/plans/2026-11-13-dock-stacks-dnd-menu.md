# Dock stacks drag-and-drop and menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drag a folder onto the elementary dock to add it as a stack, and right-click a stack to change its view, sort and display, open it, or remove it, with the dock persisting the list.

**Architecture:** A new display-free `StackList` holds the list edits and serialization, unit-tested; `StackStore` writes the `stacks` key through it and splices only changed entries. `ItemManager`'s existing file drop gains a folder case; `StackItem` gains a secondary-click `Gtk.PopoverMenu` backed by stateful actions.

**Tech Stack:** Vala, GTK 4, GLib/GIO settings, meson; built and tested through Nix.

**Spec:** `docs/superpowers/specs/2026-11-13-dock-stacks-dnd-menu-design.md`

## Global Constraints

- All dock code is in `~/Code/elementary-dock-extras` (branch `extras`). The work lands as ONE new commit `feat: stack drag-and-drop and menu`, placed after `1cace32d feat: sharp icons` and before `1aea62d8 docs: README…`. Work in commits on top of `extras`, then reorder at the end (Task 5). Never push until Task 5.
- Read the fork's `CLAUDE.md` first: Vala pitfalls (no lambdas in `Object (...)` chain-ups; signal handlers on long-lived objects are methods; `warning ()` patterns need a leading `*`).
- Default for a dropped folder: `fan`, `date-added`, `stack`.
- Saved sources under the home directory are written `~/<rest>`; `applications` and other absolute paths as is.
- Any write to `stacks` first checks `settings.settings_schema.has_key ("stacks")`; without it, `warning (...)` and do nothing.
- Never inject input on raider; use test hooks and `just pantheon::shot`.
- In arsfeld/nixos commit straight to master, conventional commits, no Claude mention.
- Build+unit-test command for a checkout (runs the `stacks` meson test via `doCheck`):
  `nix build --no-link -L --impure --expr '(builtins.getFlake "/home/arosenfeld/Code/nixos").nixosConfigurations.raider.pkgs.pantheon.elementary-dock.overrideAttrs { src = builtins.path { name = "elementary-dock-src"; path = /home/arosenfeld/Code/elementary-dock-extras; filter = p: t: !(builtins.elem (baseNameOf p) [".git" "build" "dist"]); }; }'`
  Referred to below as **BUILD**. A new `.vala` file need not be `git add`ed (the path is copied, not a flake).

## Review Focus

1. A folder that is already a stack, dropped again (including through a different spelling, `~/X` vs `/home/u/X`, or a trailing slash): must not duplicate; that stack bounces. → test in Task 1 (`/stack-list/add-duplicate`), handled in Task 3.
2. A drop of a regular file (not `.desktop`, not a folder): rejected as today, nothing written. → manual check in Task 3.
3. Editing a stack from its own menu while that stack's item is rebuilt: the menu popover must be popped down and unparented in teardown, no criticals. → Task 4 checks `G_MESSAGES_DEBUG=all` for `StackItem finalized` and no `CRITICAL`.
4. A stack whose folder is missing (deleted): menu still opens; Open in Files may fail with the existing `critical`; Remove works. → manual check in Task 4.
5. A stale-schema session (no `stacks` key): add/update/remove warn and change nothing, no abort. → covered by the guard in Task 2; reviewed, not tested (needs an old schema).

---

### Task 1: StackList, the display-free list logic

**Files:**
- Create: `src/Stacks/StackList.vala`
- Modify: `src/Stacks/StackConfig.vala` (add serializers), `src/Stacks/meson.build` (add `StackList.vala` to `stacks_core_sources`)
- Test: `src/Stacks/tests/StackTests.vala`

**Interfaces:**
- Produces, in `StackConfig`:
  - `public static string view_name (View v)` → `"fan"|"grid"`; `sort_name (Sort s)` → `"date-added"|"name"`; `display_name (Display d)` → `"stack"|"grid"|"folder"`. `parse` uses the same strings (keep them the exact inverse).
  - `public string saved_source ()` → `~/rest` if `source` is under `Environment.get_home_dir ()` (equal to it plus `/`), else `source`.
  - `public Variant to_variant ()` → `(ssss)`.
  - `public bool same_as (StackConfig other)` → all four fields equal.
- Produces, `public class Dock.StackList` (static methods only):
  - `public static string normalize (string path)` → `~/` expanded, then `File.new_for_path (p).get_path ()` (drops trailing slash and `..`).
  - `public static int index_of (GenericArray<StackConfig> list, string path)` → index whose `source` equals `normalize (path)`, else -1.
  - `public static GenericArray<StackConfig>? with_added (GenericArray<StackConfig> list, string path)` → copy plus `(normalize (path), FAN, DATE_ADDED, STACK)`, or null if `index_of >= 0`.
  - `public static GenericArray<StackConfig> with_removed (list, string source)`.
  - `public static GenericArray<StackConfig> with_updated (list, string source, View view, Sort sort, Display display)` → the entry replaced by a new `StackConfig`, others the same objects.
  - `public static Variant to_variant (GenericArray<StackConfig> list)` → `a(ssss)`.
  - `public static void changed_range (GenericArray<StackConfig> old_list, GenericArray<StackConfig> new_list, out uint position, out uint removed, out uint added)` → longest common prefix and suffix by `same_as`; the middle is the splice.

- [ ] **Step 1: Write the failing tests** (register each with `Test.add_func` in `main`)

```vala
GenericArray<StackConfig> two_stacks () {
    var list = new GenericArray<StackConfig> ();
    list.add (new StackConfig (Path.build_filename (Environment.get_home_dir (), "Downloads"), FAN, DATE_ADDED, STACK));
    list.add (new StackConfig ("applications", GRID, NAME, GRID));
    return list;
}

void test_list_round_trip () {        // "/stack-list/round-trip"
    var list = two_stacks ();
    var parsed = StackConfig.parse_all (StackList.to_variant (list));
    assert_cmpint (parsed.length, EQ, 2);
    assert_true (parsed[0].same_as (list[0]));
    assert_true (parsed[1].same_as (list[1]));
    assert_cmpstr (StackList.to_variant (list).get_child_value (0).get_child_value (0).get_string (), EQ, "~/Downloads");
}

void test_saved_source () {           // "/stack-list/saved-source"
    assert_cmpstr (new StackConfig ("/tmp/x", FAN, NAME, STACK).saved_source (), EQ, "/tmp/x");
    assert_cmpstr (new StackConfig ("applications", GRID, NAME, GRID).saved_source (), EQ, "applications");
    // A sibling of home that shares its prefix is not under home.
    var sibling = Environment.get_home_dir () + "x/y";
    assert_cmpstr (new StackConfig (sibling, FAN, NAME, STACK).saved_source (), EQ, sibling);
}

void test_add () {                     // "/stack-list/add"
    var added = StackList.with_added (two_stacks (), "/tmp/stuff/");
    assert_nonnull (added);
    assert_cmpint (added.length, EQ, 3);
    assert_cmpstr (added[2].source, EQ, "/tmp/stuff");
    assert_true (added[2].view == FAN && added[2].sort == DATE_ADDED && added[2].display == STACK);
}

void test_add_duplicate () {           // "/stack-list/add-duplicate"
    var home_downloads = Path.build_filename (Environment.get_home_dir (), "Downloads");
    assert_null (StackList.with_added (two_stacks (), "~/Downloads"));
    assert_null (StackList.with_added (two_stacks (), home_downloads + "/"));
    assert_cmpint (StackList.index_of (two_stacks (), home_downloads), EQ, 0);
}

void test_update_remove () {           // "/stack-list/update-remove"
    var list = two_stacks ();
    var updated = StackList.with_updated (list, "applications", FAN, NAME, FOLDER);
    assert_true (updated[0] == list[0]);              // untouched entry is the same object
    assert_true (updated[1].view == FAN && updated[1].display == FOLDER);
    var removed = StackList.with_removed (list, "applications");
    assert_cmpint (removed.length, EQ, 1);
    assert_true (removed[0] == list[0]);
}

void test_changed_range () {           // "/stack-list/changed-range"
    var list = two_stacks ();
    uint pos, removed, added;
    StackList.changed_range (list, StackList.with_updated (list, "applications", FAN, NAME, FOLDER), out pos, out removed, out added);
    assert_cmpuint (pos, EQ, 1); assert_cmpuint (removed, EQ, 1); assert_cmpuint (added, EQ, 1);
    StackList.changed_range (list, StackList.with_added (list, "/tmp"), out pos, out removed, out added);
    assert_cmpuint (pos, EQ, 2); assert_cmpuint (removed, EQ, 0); assert_cmpuint (added, EQ, 1);
    StackList.changed_range (list, two_stacks (), out pos, out removed, out added);
    assert_cmpuint (removed, EQ, 0); assert_cmpuint (added, EQ, 0);
}
```

- [ ] **Step 2: Run BUILD; expect a compile failure naming `StackList` / `same_as`.**

- [ ] **Step 3: Implement the `StackConfig` additions and `StackList.vala` per the Interfaces block; add the file to `stacks_core_sources`.**

`changed_range`: prefix `p` while `p < min(len)` and `same_as`; suffix `s` while `s < min(len) - p` and the entries from the ends are `same_as`; `position = p`, `removed = old.length - p - s`, `added = new.length - p - s`.

- [ ] **Step 4: Run BUILD; expect success (the `stacks` test passes inside the build log).**

- [ ] **Step 5: Commit** (`git add src/Stacks; git commit -m "wip: StackList"`).

### Task 2: StackStore writes and partial splices

**Files:**
- Modify: `src/Stacks/StackStore.vala`, `src/ItemManager.vala` (expose the store)

**Interfaces:**
- Consumes: `StackList.*`, `StackConfig.parse_all` (Task 1).
- Produces:
  - `ItemManager.get_default ().stacks` → `public StackStore stacks { get; }` (rename the private `stack_store` field into this property).
  - `StackStore`: `public bool add (string path)` (false on duplicate or no key), `public void remove (string source)`, `public void update (string source, StackConfig.View view, StackConfig.Sort sort, StackConfig.Display display)`.
  - `StackStore.current` (private `GenericArray<StackConfig>` mirroring `store`).

- [ ] **Step 1: Implement.** `load ()` parses into a new list, calls `StackList.changed_range (current, parsed, …)`, splices only that range of `store` with `parsed`'s slice, then sets `current = parsed`. Each write builds the new list with `StackList.with_*` and calls a private `save (GenericArray<StackConfig>)` that guards on `has_key ("stacks")` (warning text: `"The io.elementary.dock schema has no 'stacks' key (stale session schema?); not saving stacks"`) and then `settings.set_value ("stacks", StackList.to_variant (list))`. The `changed` signal then runs `load ()`; do not splice in `save`.
- [ ] **Step 2: Run BUILD; expect success.**
- [ ] **Step 3: Check on raider.** `just pantheon::dock-run /tmp/dock.log ~/Code/elementary-dock-extras G_MESSAGES_DEBUG=all`, then `gsettings` (with `GSETTINGS_SCHEMA_DIR` set to the build's schemas dir as `dock-run` does) change one field of the second stack with `set io.elementary.dock stacks …`. Expected in `/tmp/dock.log`: `StackItem teardown` for that stack's source only, not the others.
- [ ] **Step 4: Commit** (`wip: StackStore writes`).

### Task 3: Folder drop

**Files:**
- Modify: `src/ItemManager.vala`, `src/Stacks/StackItem.vala` (public bounce)

**Interfaces:**
- Consumes: `StackStore.add`, `StackList.index_of`, `StackStore.configs`.
- Produces: `StackItem.animate_launch ()` becomes `public`. `ItemManager` private `StackItem? find_stack_item (string source)` walking `stack_group`'s children (keep `stack_group` as a field). `public void add_folder_stack (string path)`: if a stack exists, bounce it and return; else `stacks.add (path)`.

- [ ] **Step 1: Implement.** In the `notify["value"]` handler, before `DesktopAppInfo`: if `file.query_file_type (NONE, null) == DIRECTORY`, set field `File? pending_folder = file` and return; if a stack already exists for it, call `drop_target_file.reject ()` and bounce that item. In `drop`, if `pending_folder != null`, `add_folder_stack (pending_folder.get_path ())`, clear it, return true. In `leave`, clear it. Leave the `.desktop` path untouched.
- [ ] **Step 2: Test hook.** `DOCK_STACKS_DROP=<path>`: in `construct`, after `maybe_zoom_for_test ()`, `Timeout.add_once (1000, …)` calling `add_folder_stack`. Use a method, not a lambda capturing locals.
- [ ] **Step 3: Run BUILD; expect success.**
- [ ] **Step 4: Check on raider.** `mkdir -p /tmp/stack-test && touch /tmp/stack-test/{a,b}.txt`; `just pantheon::dock-run /tmp/dock.log ~/Code/elementary-dock-extras DOCK_STACKS_DROP=/tmp/stack-test`; `just pantheon::shot /tmp/dock-drop.png 1000 1300 1440 140`, read it: a new stack at the end of the stacks. Run the same command again: no second stack (the existing one bounces). Ask the user to drag a folder and a plain file from Files once, since a real drag cannot be simulated: folder adds, plain file does nothing.
- [ ] **Step 5: Commit** (`wip: folder drop`).

### Task 4: Right-click menu

**Files:**
- Modify: `src/Stacks/StackItem.vala`

**Interfaces:**
- Consumes: `ItemManager.get_default ().stacks.update/remove`, `source.open_location ()`.
- Produces: action group `stack` with `view`, `sort`, `display` (stateful `s`, parameter `s`, state = current `StackConfig.*_name`), `open`, `remove`.

- [ ] **Step 1: Implement.** `gesture_click.button = 0`; `on_released` switches on `get_current_button ()`: `BUTTON_PRIMARY` → `popover_menu.popup ()`; `BUTTON_SECONDARY` → `menu_popover.popup ()` and `popover_tooltip.popdown ()`. A touch-only `Gtk.GestureLongPress` opens `menu_popover`. Build a `GLib.Menu`: sections "View as" (Fan `stack.view::fan`, Grid `::grid`), "Sort by" (Date Added, Name; omitted for `is_applications`), "Display as" (Stack, Grid Preview, Folder), then a section with "Open in Files" (omitted for `is_applications`) and "Remove from Dock". `menu_popover = new Gtk.PopoverMenu.from_model (menu) { autohide = true, position = TOP }`, `set_offset (0, -1)`, `set_parent (this)`. Activation handlers are methods; `view/sort/display` parse the string and call `update` with the other two fields from `config`. In `teardown ()`, `menu_popover.popdown ()` and `unparent ()` next to `popover_menu`'s.
- [ ] **Step 2: Test hook.** `DOCK_STACKS_MENU=<index>`: extend `maybe_open_for_test` so the same index match opens `menu_popover` instead when this variable is set.
- [ ] **Step 3: Run BUILD; expect success.**
- [ ] **Step 4: Check on raider.** `just pantheon::dock-run /tmp/dock.log ~/Code/elementary-dock-extras DOCK_STACKS_MENU=0 G_MESSAGES_DEBUG=all`, shot the dock area after 2 s, read it: the menu with radios showing the current values. Repeat with the Applications stack's index: no Sort, no Open. Then change a field by `gsettings set` while the menu is open; `/tmp/dock.log` has `StackItem finalized` for it and no `CRITICAL`. Ask the user to right-click once and pick an option to confirm the action path.
- [ ] **Step 5: Commit** (`wip: stack menu`).

### Task 5: Fold, document, release, bump

**Files:**
- Modify (fork): `CLAUDE.md` (the two hooks, in the Test hooks list), `README.md` (one line: drag a folder in, right-click to configure)
- Modify (nixos): `packages/elementary-dock-extras/package.nix` (rev, hash, version date), `modules/desktop/pantheon-dock/default.nix` (`dockStacks` description: "Initial folder stacks … the dock saves its own list once a stack is added, changed or removed; `dconf reset /io/elementary/dock/stacks` returns to this one.")

- [ ] **Step 1:** In the fork, squash the `wip:` commits into one `feat: stack drag-and-drop and menu` (message body names the spec path), put the doc lines into the README/CLAUDE commit as fixups, and move the feature commit before `docs: README…` with `GIT_SEQUENCE_EDITOR` scripting (`git rebase -i 8.3.3`). Expected `git log --oneline 8.3.3..`: stacks, zoom, sharp icons, stack drag-and-drop and menu, docs, build.
- [ ] **Step 2:** Run BUILD once more on the rebased tree; expect success.
- [ ] **Step 3:** `git push --force-with-lease origin extras`; watch the fork's CI (`gh run watch`) until the .deb build is green (it builds against elementary OS's older GTK; `Gtk.PopoverMenu`/`GestureLongPress` are old API, so no `HAS_GTK_4_22` gate expected).
- [ ] **Step 4:** In nixos, set `rev` to the new head, update `hash` (build once with `lib.fakeHash` and copy the reported one), set the version date; edit the `dockStacks` description; `nix build .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock`; expect success.
- [ ] **Step 5:** `just fmt`; commit `feat(modules): drag folders onto the dock to make stacks, right-click to configure`; push origin master. Deploying (`nix develop -c just deploy raider`) and the re-login it needs are left to the user.
