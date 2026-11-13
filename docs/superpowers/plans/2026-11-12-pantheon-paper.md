# pantheon-paper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PaperWM-style scrolling tiling in Pantheon as a Gala plugin, installed on raider and blackbird.

**Architecture:** A Vala Gala plugin in a new repo, `arsfeld/pantheon-paper`. Its core is pure code with no Mutter types: a strip model (columns of window ids), a layout function (strip + work area → rectangles), a tiling predicate and drop hit-testing, all unit-tested with meson. A thin controller binds Mutter signals, keybindings and pointer events to that core, and applies the result with `move_resize_frame`. The nixos repo packages the plugin, installs it and clears Gala's conflicting bindings. A headless Gala (`--headless --virtual-monitor`) with its own session bus is the end-to-end test bed.

**Tech Stack:** Vala, meson, Gala 8.6.2 plugin API (`gala.vapi`), Mutter 48 (`libmutter-16`), libgee, GLib.Test; Nix (flake-parts feature, `packages/`).

**Spec:** `docs/superpowers/specs/2026-11-12-pantheon-paper-design.md`

## Global Constraints

- Plugin repo: `github.com/arsfeld/pantheon-paper`, local checkout `~/Code/pantheon-paper`, commit straight to `master` (no branches, no worktrees).
- Build against the Mutter Gala itself uses: probe `libmutter-16` (Mutter 48, with Vala defines `HAS_MUTTER47`, `HAS_MUTTER48`) exactly as `arsfeld/pantheon-global-menu`'s `pantheon/meson.build` does, with Mutter vapis carried in `vapi/` (copy `libmutter-16.{vapi,deps}`, `mutter-clutter-16.*`, `mutter-cogl-16.*`, `mutter-mtk-16.vapi`, `xfixes-4.0.vapi` from that repo's `pantheon/vapi/`). Mutter 46 support is not needed.
- Install to `$prefix/lib/gala/plugins`; NixOS Gala loads from `/run/current-system/sw/lib/gala/plugins`.
- Constants: gap `GAP = 8` px, sliver `SLIVER = 10` px, animation `ANIM_MS = 200` with `Clutter.AnimationMode.EASE_OUT_QUAD`, new-column preset `HALF`, width presets 1/3, 1/2, 2/3.
- Windows are identified in pure code by `uint64` (`Meta.Window.get_id()`); `0` means none.
- GSettings schema id `io.github.arsfeld.paper.keybindings`; log domain `pantheon-paper`.
- Bindings and defaults (exact): `focus-left` `<Super>Left`, `focus-right` `<Super>Right`, `focus-up` `<Super>Up`, `focus-down` `<Super>Down`, `move-left` `<Super><Shift>Left`, `move-right` `<Super><Shift>Right`, `move-up` `<Super><Shift>Up`, `move-down` `<Super><Shift>Down`, `cycle-width` `<Super>r`, `toggle-full` `<Super>f`, `slurp` `<Super>i`, `barf` `<Super>o`, `center` `<Super>c`, `toggle-float` `<Super><Shift>f`.
- Strips exist on the primary monitor only; a crash in the plugin ends the Pantheon session, so every Mutter-facing handler checks the window is still managed.
- nixos repo: conventional commits, scope `modules` (or `raider`); a new file must be `git add`ed before `nix build` sees it; build hosts one at a time, never in parallel.
- Animations honour `org.gnome.desktop.interface enable-animations` (false → apply instantly).

## Review Focus

1. **A window closes during an animation or between a model update and `apply`** — expect no crash and the strip closing the gap. Test: Task 4 demo step `close-mid-animation`; Task 2 `test_remove_focused_*`.
2. **A window whose minimum width exceeds its preset** (a terminal at 1/3 on a narrow screen, apps with large min sizes) — expect the column to take the granted width and its neighbours to shift, with no re-layout loop. Test: Task 3 `test_width_hint_widens_column`; Task 4 loop guard.
3. **Commands on an empty or single-window strip** (Super+I with no next column, Super+O in a one-window column, focus keys with nothing focused) — expect no-ops, never an exception. Test: Task 2 `test_ops_on_empty_strip`, `test_slurp_without_next`, `test_barf_single`.
4. **Apps that map maximized or ask to maximize** (browsers restoring a maximized session, titlebar double-click) — expect the window to tile, with maximize turned into the column's full-width toggle. Test: Task 4 demo step `maximize`.
5. **A window that becomes transient or changes monitor after it was tiled** (a dialog-like window gaining a parent, dragged to a secondary display) — expect it to leave the strip and float. Test: Task 4 `test_should_tile_*` and the controller re-evaluating on `notify::transient-for` and `window-entered-monitor`.

---

### Task 1: Plugin skeleton that loads in a headless Gala

**Files (plugin repo `~/Code/pantheon-paper`):**
- Create: `meson.build`, `vapi/*` (copied, see Global Constraints), `src/Plugin.vala`, `data/io.github.arsfeld.paper.keybindings.gschema.xml`, `tests/meson.build` (empty test list for now), `README.md`, `LICENSE` (GPL-3.0-or-later, as global-menu)

**Files (nixos repo):**
- Create: `packages/pantheon-paper/package.nix` (pinned to the skeleton commit; Task 7 bumps it)
- Modify: `just/pantheon.just` (new recipes `paper-shell`, `paper-gala`, `paper-run`, `paper-stop`)

**Interfaces:**
- Produces: `meson.build` with a static library target `paper_core` (sources under `src/core/`, deps glib/gobject/gee only) that later tasks add files to and tests link against; the `gala-paper` shared module (core + `src/*.vala`); `public Gala.PluginInfo register_plugin ()` returning `name = "PaperWM tiling"`, `author = "arsfeld"`, `plugin_type = typeof (Paper.Plugin)`, `provides = Gala.PluginFunction.ADDITION`, `load_priority = Gala.LoadPriority.IMMEDIATE` (field names as in `gala.vapi`'s `Gala.PluginInfo`).
- Produces: `just pantheon::paper-run <build-dir> [env...]` starting a headless Gala that loads the plugin from `<build-dir>`, logging to `/tmp/paper-gala.log`, and `just pantheon::shot`-compatible capture against it (see Step 6).

- [ ] **Step 1: Create the GitHub repo.** Confirm with the user first (outward-facing), then `gh repo create arsfeld/pantheon-paper --public --description "PaperWM-style scrolling tiling for Pantheon (Gala plugin)"` and clone to `~/Code/pantheon-paper`.

- [ ] **Step 2: Write `meson.build`.** Project `pantheon-paper`, languages vala and c. Copy the Mutter probe block from global-menu's `pantheon/meson.build`, keeping only the `['16', '48', ['HAS_MUTTER47', 'HAS_MUTTER48']]` row. `paper_core` static library from `src/core/*.vala` (none yet: start with `src/core/Types.vala` holding `namespace Paper { public const int GAP = 8; public const int SLIVER = 10; public const uint ANIM_MS = 200; public struct Rect { public int x; public int y; public int width; public int height; } }`). `gala-paper` shared module with the same install dir and `install_rpath` as global-menu's Gala module. Install the gschema to `datadir/glib-2.0/schemas` and run `gnome.post_install(glib_compile_schemas: true)`. `subdir('tests')`.

- [ ] **Step 3: Write `src/Plugin.vala`** — `Paper.Plugin : Gala.Plugin` whose `initialize` logs `pantheon-paper: loaded on <n> monitor(s)` with `message()` and stores `wm`; `destroy` is empty for now. Write the gschema with the 14 keys and defaults from Global Constraints (type `as`).

- [ ] **Step 4: Package and dev shell.** Commit and push the skeleton, then write `packages/pantheon-paper/package.nix` pinned to that commit (contents as described in Task 7) and `git add` it. Add `paper-shell *cmd` to `just/pantheon.just`: `nix develop --impure --expr '(builtins.getFlake (toString <repo>)).nixosConfigurations.raider.pkgs.callPackage <repo>/packages/pantheon-paper/package.nix {}' -c {{cmd}}`, so the shell carries exactly the Gala and Mutter 48 the package builds against (the top-level `mutter` may differ). Build: `cd ~/Code/pantheon-paper && just -f /home/arosenfeld/Code/nixos/justfile pantheon::paper-shell bash -c 'meson setup build && ninja -C build'`. Expected: `build/libgala-paper.so` exists. Every later `meson`/`ninja` command in this plan runs inside `paper-shell`.

- [ ] **Step 5: Add `paper-gala` and `paper-run` to `just/pantheon.just`.** `paper-gala` builds `pantheon.gala.overrideAttrs` whose `postPatch` additionally rewrites `/run/current-system/sw/lib/gala/plugins` to `/tmp/paper-gala-plugins` (dev-only; never installed). `paper-run build_dir *env` copies `<build_dir>/libgala-paper.so` into a fresh `/tmp/paper-gala-plugins`, compiles the schema into a temp dir, and runs `dbus-run-session -- env GSETTINGS_BACKEND=memory GSETTINGS_SCHEMA_DIR=<dir> {{env}} <paper-gala>/bin/gala --headless --virtual-monitor 1920x1080 --wayland-display paper-0 --no-x11` in the background, logging to `/tmp/paper-gala.log`, and writes the bus address to `/tmp/paper-gala.bus`. A `paper-stop` recipe kills it.

- [ ] **Step 6: Probe the test bed.** Run: `just pantheon::paper-run ~/Code/pantheon-paper/build` then look for the load line with the Grep tool on `/tmp/paper-gala.log`. Expected: `pantheon-paper: loaded on 1 monitor(s)`. Then capture: `DBUS_SESSION_BUS_ADDRESS=$(< /tmp/paper-gala.bus) just pantheon::shot /tmp/paper-probe.png` and read the PNG. If headless capture fails, switch `paper-run` to `--nested` (a window on raider's own screen, captured with the normal `shot`) and record which one worked in a comment in the recipe. Either way the plugin must be seen loading.

- [ ] **Step 7: Commit** nixos: `feat(modules): pantheon-paper package and headless Gala recipes` (the package is not installed anywhere yet).

### Task 2: Strip model and operations

**Files:**
- Create: `src/core/Strip.vala`, `tests/test_strip.vala`
- Modify: `tests/meson.build` (add `test('strip', executable(... link_with: paper_core))`)

**Interfaces:**
- Consumes: `Paper.Rect`, constants (Task 1).
- Produces (namespace `Paper`):
  - `public enum Preset { THIRD, HALF, TWO_THIRDS; public double fraction (); public Preset next (); }` — fractions 1/3, 1/2, 2/3; `next` cycles THIRD→HALF→TWO_THIRDS→THIRD.
  - `public enum DropKind { NONE, INTO_COLUMN, NEW_COLUMN }`; `public struct DropTarget { public DropKind kind; public int column; public int row; }` (`NEW_COLUMN.column` is the insertion index).
  - `public class Column : Object { public Preset preset; public int free_px; public bool full; public Gee.ArrayList<uint64?> windows; public Gee.ArrayList<double?> shares; public int active_row; }` — `free_px == 0` means use the preset; shares sum to 1.
  - `public class Strip : Object { public Gee.ArrayList<Column> columns; public int scroll_x; public uint64 focused; }` with methods:
    `bool contains (uint64 id)`, `int column_of (uint64 id)`, `void insert_after_focused (uint64 id)`, `void append (uint64 id)`, `void remove (uint64 id)`, `void focus (uint64 id)`, `void focus_column (int delta)`, `void focus_row (int delta)`, `void move_column (int delta)`, `void move_in_column (int delta)`, `void cycle_width (int work_width)`, `void toggle_full ()`, `void slurp ()`, `void barf ()`, `void set_free_width (uint64 id, int px)`, `void set_shares (int column, double[] shares)`, `void move_to (uint64 id, DropTarget t)`.

Rules the tests pin: new columns get `HALF` and equal shares; any change to a column's window list resets its shares to equal; `remove` drops an emptied column and moves focus to the next row of the same column, else the previous row, else the left column's `active_row` window, else the right column's, else `0`; `focus_column`/`focus_row` clamp at the ends; `move_*` at an end is a no-op; `slurp` moves the next column's top window to the bottom of the focused column (no-op without a next column); `barf` moves the focused window into a new column right of its own, keeping the preset (no-op if alone); `cycle_width` from `free_px > 0` snaps to the preset whose pixel width (`round(work_width * fraction) - GAP`) is nearest and clears `free_px`, otherwise advances `next()`; both clear `full`; `set_shares` normalises to sum 1 and ignores a length mismatch; `move_to` removes then reinserts (into a column at `row` clamped, or as a new `HALF` column at `column`), and dropping a window onto its own position leaves the strip unchanged.

- [ ] **Step 1: Write the failing tests** in `tests/test_strip.vala` with `GLib.Test.add_func`, one per rule above, named `/strip/<rule>`, including:

```vala
Test.add_func ("/strip/ops_on_empty_strip", () => {
    var s = new Paper.Strip ();
    s.focus_column (1); s.focus_row (-1); s.slurp (); s.barf ();
    s.cycle_width (1920); s.toggle_full (); s.move_column (1); s.remove (42);
    assert (s.columns.size == 0 && s.focused == 0);
});
Test.add_func ("/strip/slurp_then_barf_roundtrip", () => {
    var s = new Paper.Strip ();
    s.insert_after_focused (1); s.insert_after_focused (2);
    s.focus (1); s.slurp ();
    assert (s.columns.size == 1 && s.columns[0].windows.size == 2);
    assert (s.columns[0].shares[0] == 0.5);
    s.focus (2); s.barf ();
    assert (s.columns.size == 2 && s.columns[1].windows[0] == 2 && s.focused == 2);
});
Test.add_func ("/strip/cycle_width_from_free_snaps_nearest", () => {
    var s = new Paper.Strip (); s.insert_after_focused (1);
    s.set_free_width (1, 700);           // 1920: THIRD=632 HALF=952 TWO_THIRDS=1272
    s.cycle_width (1920);
    assert (s.columns[0].preset == Paper.Preset.THIRD && s.columns[0].free_px == 0);
});
```
plus `/strip/remove_focused_prefers_same_column`, `/strip/remove_focused_falls_back_left`, `/strip/remove_last_window_drops_column`, `/strip/insert_after_focused_order`, `/strip/focus_column_clamps`, `/strip/move_column_at_end_noop`, `/strip/slurp_without_next`, `/strip/barf_single`, `/strip/set_shares_normalises`, `/strip/move_to_new_column`, `/strip/move_to_into_column_clamps_row`, `/strip/move_to_own_slot_noop`.

- [ ] **Step 2: Run to see them fail.** Run: `meson test -C build strip -v`. Expected: build fails, `Paper.Strip` undefined.
- [ ] **Step 3: Implement `src/core/Strip.vala`.**
- [ ] **Step 4: Run.** `meson test -C build strip -v` → all pass.
- [ ] **Step 5: Commit** `feat: strip model and operations`, push.

### Task 3: Layout, width hints and scrolling

**Files:**
- Create: `src/core/Layout.vala`, `tests/test_layout.vala`
- Modify: `tests/meson.build`

**Interfaces:**
- Consumes: `Strip`, `Column`, `Preset`, `Rect`, constants.
- Produces:
  - `public interface WidthHints : Object { public abstract int min_width (uint64 id); }` (0 = unknown) and `public class NoHints : Object, WidthHints` returning 0.
  - `public struct Placement { public uint64 id; public Rect rect; public bool parked; }`
  - `public class LayoutResult : Object { public Gee.ArrayList<Placement?> windows; public Gee.ArrayList<Rect?> columns; }`
  - `public LayoutResult Paper.layout (Strip s, Rect work, WidthHints hints)`
  - `public void Paper.scroll_to_focus (Strip s, Rect work, WidthHints hints)`, `public void Paper.center_focus (Strip s, Rect work, WidthHints hints)`, `public void Paper.pan (Strip s, int dx, Rect work, WidthHints hints)`.

Geometry (pins): column width = `work.width` if `full`, else `free_px` if set, else `round(work.width * fraction) - GAP`; then `max(that, max min_width of its windows)`. Strip coordinate of column i: `x_0 = 0`, `x_{i+1} = x_i + w_i + GAP`. Screen x = `work.x + x_i - scroll_x`. Window heights: `(work.height - GAP*(n-1)) * share`, rounded, with the last row taking the remainder; rows separated by `GAP`. A column is **parked** when fewer than `SLIVER` px of it would fall inside `[work.x, work.x + work.width)`: past the right edge it gets `x = work.x + work.width - SLIVER`, past the left `x = work.x + SLIVER - w`; parked columns keep their width and height. `scroll_to_focus` moves `scroll_x` the minimum to make the focused column fully visible (left-aligned if wider than the work area). `center_focus` sets `scroll_x` to put the column's centre at the work area's centre. `pan` adds `dx` and clamps `scroll_x` to `[-work.width/2, total_width - work.width/2]`.

- [ ] **Step 1: Write failing tests** (`/layout/...`, work area `{0, 32, 1920, 1048}` unless stated): `two_halves_side_by_side` (columns at x 0 and 960, width 952), `stacked_heights_share_column` (two windows at shares 0.5 → heights 520 and 520, second at y 32+520+8), `parks_far_right` (four halves, scroll 0 → column 3 at x 1910, `parked`), `parks_far_left`, `straddling_column_not_parked` (scroll 400: column 0 at x -400, not parked), `full_column_takes_work_width`, `width_hint_widens_column` (hint 800 on a THIRD column → width 800 and the next column at x 808), `scroll_to_focus_minimal_move`, `scroll_to_focus_wide_column_left_aligns`, `center_focus`, `pan_clamps`.
- [ ] **Step 2: Run** `meson test -C build layout -v` → FAIL (undefined).
- [ ] **Step 3: Implement `src/core/Layout.vala`.**
- [ ] **Step 4: Run** → PASS; also `meson test -C build` all green.
- [ ] **Step 5: Commit** `feat: layout with parking, width hints and scrolling`, push.

### Task 4: Controller — tiling windows on screen

**Files:**
- Create: `src/core/Tiling.vala`, `tests/test_tiling.vala`, `src/Controller.vala`, `src/Applier.vala`, `src/Demo.vala`
- Modify: `src/Plugin.vala`, `tests/meson.build`, `meson.build`

**Interfaces:**
- Consumes: everything in `src/core/`.
- Produces:
  - Pure: `public struct WindowFacts { public bool normal_type; public bool has_transient_parent; public bool fullscreen; public bool minimized; public bool on_primary; public bool floating; }` and `public bool Paper.should_tile (WindowFacts f)` — true only for normal, no parent, not fullscreen, not minimized, on primary, not floating.
  - `Paper.Controller : Object` constructed with `(Gala.WindowManager wm)`, holding `Gee.HashMap<Meta.Workspace, Strip>`, `Gee.HashSet<uint64?> floating`, and the methods later tasks call: `Strip? current_strip ()`, `Meta.Window? window_for (uint64 id)`, `Rect work_area ()` (primary monitor work area of the active workspace), `WidthHints hints ()` (current frame widths of windows Mutter would not shrink: the frame width when it exceeds the requested width), `void relayout (bool animate = true)`, `void toggle_float (Meta.Window w)`, `void destroy ()`.
  - `Paper.Applier` with `void apply (LayoutResult r, bool animate)`.
  - `Paper.Demo` started when `PAPER_DEMO=<n>` is set: spawns `n` windows of `PAPER_DEMO_CMD` (default `io.elementary.terminal`), waits for them, runs a named step list with 2 s between steps, and logs `paper-demo: step <i> <name>` before each step and `paper-demo: done` at the end.

Controller behaviour (pins):
- On `window-created` (deferred until the window is shown, via `shown` or an idle), on startup for every existing window in stacking order (`append`, others `insert_after_focused`), and whenever `notify::fullscreen`, `notify::minimized`, `notify::transient-for`, `workspace-changed` or `window-entered-monitor` fires, recompute `should_tile` and add the window to or remove it from the right workspace's strip. A window returning from fullscreen goes back to its old slot (remember column and row at removal); one returning from minimized is `insert_after_focused`; one moved to another workspace is `append`ed there.
- A tiled window that becomes maximized is unmaximized and its column's `full` toggled on.
- `focus` on the display → `strip.focus(id)` then `scroll_to_focus` and `relayout`.
- `unmanaged` → remove from the model **before** anything else touches it; Applier skips ids whose `window_for` is null and cancels their transitions.
- Loop guard: `size-changed` triggers a relayout only when not inside `apply` and the window's frame width differs from the last value recorded for it.
- Applier: per placement, skip if the frame rect already matches; otherwise record the actor's current position, `move_resize_frame (false, x, y, w, h)`, and if animating, set the actor's translation to old minus new and ease translation back to 0 over `ANIM_MS` with `EASE_OUT_QUAD`. Animations off (`enable-animations` false) → no easing.

- [ ] **Step 1: Failing tests** `tests/test_tiling.vala`: `/tiling/normal_window_tiles`, `/tiling/transient_floats`, `/tiling/fullscreen_leaves`, `/tiling/minimized_leaves`, `/tiling/secondary_monitor_floats`, `/tiling/floating_toggle_floats`.
- [ ] **Step 2: Run** `meson test -C build tiling -v` → FAIL.
- [ ] **Step 3: Implement `src/core/Tiling.vala`**, run → PASS.
- [ ] **Step 4: Implement `Controller`, `Applier`, wire them in `Plugin.initialize`/`destroy`** (destroy disconnects every handler and resets nothing on windows).
- [ ] **Step 5: Implement `Demo`** with the step list: `open` (the n windows), `focus-left`, `focus-left`, `maximize` (calls `maximize(BOTH)` on the focused window), `close-mid-animation` (focus-right, then 50 ms later `delete` the focused window), `fullscreen-roundtrip`, `minimize-restore`.
- [ ] **Step 6: End to end.** Run: `ninja -C build && just pantheon::paper-run ~/Code/pantheon-paper/build PAPER_DEMO=4`. Capture after each logged step with `just pantheon::shot` against the headless bus and read every PNG. Expected: four columns of width 952 with the fourth parked as a 10 px sliver on the right; after `maximize` the focused column spans the screen; after `close-mid-animation` the log shows no `CRITICAL` and Gala is still running (`pgrep -f paper-0`) and the gap is closed; `paper-demo: done` reached.
- [ ] **Step 7: Commit** `feat: tile windows into per-workspace strips`, push.

### Task 5: Keybindings

**Files:**
- Create: `src/Keys.vala`
- Modify: `src/Plugin.vala`, `src/Demo.vala`

**Interfaces:**
- Consumes: `Controller.current_strip/relayout/toggle_float/window_for/work_area/hints`, `Strip` ops, `scroll_to_focus`, `center_focus`.
- Produces: `Paper.Keys` constructed with `(Meta.Display display, Controller c)`; `void destroy ()` removes all 14 bindings with `display.remove_keybinding`.

Each binding (`display.add_keybinding (name, settings, Meta.KeyBindingFlags.NONE, handler)`) runs its strip op, then for focus changes activates the newly focused window with `window.activate (timestamp)` (the `focus` signal then scrolls), and for every other op calls `scroll_to_focus` (or `center_focus` for `center`) and `relayout`. `cycle-width` passes `work_area().width`. `toggle-float` calls `Controller.toggle_float`, which removes the window from the strip (it keeps its current geometry) or re-tiles it with `insert_after_focused`.

- [ ] **Step 1: Implement `src/Keys.vala`** and create it in `Plugin.initialize`.
- [ ] **Step 2: Extend Demo** with a `keys` step list run when `PAPER_DEMO_KEYS=1`: it calls each binding's handler by name in table order (no input injection), logging the name.
- [ ] **Step 3: End to end.** Run `just pantheon::paper-run ~/Code/pantheon-paper/build PAPER_DEMO=3 PAPER_DEMO_KEYS=1`, capture after each step and read the PNGs. Expected: `cycle-width` steps the focused column 952 → 1272 → 632; `slurp` stacks two windows in one column with equal heights; `barf` splits them again; `move-left` swaps column order; `center` centres the focused column; `toggle-float` leaves that window in place and closes the gap behind it.
- [ ] **Step 4: Check collisions on raider.** Run `gsettings list-recursively | grep -E "<Super>(Left|Right|Up|Down|r|f|i|o|c)'|<Super><Shift>(Left|Right|Up|Down|f)'"` in the live session (DCONF_PROFILE as set by the desktop module). Any hit other than the keys Task 7 clears gets the plugin's default moved in the gschema and the spec's key table, and is noted in the commit.
- [ ] **Step 5: Commit** `feat: keyboard bindings`, push.

### Task 6: Mouse — Super+scroll, drag to reorder, resize

**Files:**
- Create: `src/core/Drop.vala`, `tests/test_drop.vala`, `src/Mouse.vala`
- Modify: `src/Plugin.vala`, `tests/meson.build`, `src/Demo.vala`

**Interfaces:**
- Consumes: `LayoutResult`, `Strip.move_to`, `set_free_width`, `set_shares`, `pan`, Controller.
- Produces:
  - Pure: `public DropTarget Paper.hit_test (LayoutResult r, Strip s, uint64 dragged, int x, int y)` — over the middle third of a column (excluding the dragged window's own single-window column) → `INTO_COLUMN` with `row` = number of that column's windows whose vertical centre is above `y`; over its left third → `NEW_COLUMN` at that column's index, right third → index + 1; anywhere else → `NONE`.
  - Pure: `public double[] Paper.shares_from_heights (int[] heights)`.
  - `Paper.Mouse` constructed with `(Gala.WindowManager wm, Controller c)`, `void destroy ()`.

Behaviour: `Clutter.Event.add_filter` on `wm.stage` catches `SCROLL` events with `SUPER_MASK`: smooth deltas pan by `dx * 40` (vertical deltas count as horizontal), discrete steps by ±200 px; return `EVENT_STOP`. On `display.grab-op-begin` with a moving op on a tiled window, start a 16 ms timer reading the pointer (`display.get_cursor_tracker ().get_pointer`) and drawing a translucent indicator (`Clutter.Actor` with the accent colour at 30 % alpha, in `wm.window_group` above windows) over the column or gap `hit_test` returns. On `grab-op-end`: moving → `move_to` (NONE → no change) and relayout; resizing east/west → `set_free_width (id, frame width)`; resizing north/south on a stacked window → `set_shares (col, shares_from_heights(current frame heights))`; then relayout.

- [ ] **Step 1: Failing tests** `tests/test_drop.vala`: `/drop/middle_third_into_column`, `/drop/row_from_pointer_y`, `/drop/left_third_new_column_before`, `/drop/right_third_new_column_after`, `/drop/own_single_column_is_none`, `/drop/outside_is_none`, `/drop/shares_from_heights_normalised`.
- [ ] **Step 2: Run** `meson test -C build drop -v` → FAIL.
- [ ] **Step 3: Implement `src/core/Drop.vala`**, run → PASS.
- [ ] **Step 4: Implement `src/Mouse.vala`** and wire it in.
- [ ] **Step 5: Extend Demo** with `PAPER_DEMO_MOUSE=1` steps that call the grab-end handling and the pan handler directly with synthetic coordinates (no input injection): drop window 1 into column 2's middle, drop it in the gap after column 0, pan +600.
- [ ] **Step 6: End to end** as in Task 4, with `PAPER_DEMO=3 PAPER_DEMO_MOUSE=1`; read the captures. Expected: the stacked column after the first drop, a new column after the second, the strip shifted 600 px after the pan.
- [ ] **Step 7: Commit** `feat: Super+scroll, drag to reorder and resize`, push.

### Task 7: Package, module and install on raider

**Files (nixos repo):**
- Modify: `packages/pantheon-paper/package.nix` (bump `rev`/`hash` to the plugin's final commit)
- Create: `modules/desktop/pantheon-paper.nix`
- Modify: `modules/desktop/desktop.nix` (import `features.pantheon-paper` next to `features.pantheon-globalmenu`), `CLAUDE.md` (features table row for `desktop` mentions it; a short "pantheon-paper" subsection), `docs/superpowers/specs/2026-11-12-pantheon-paper-design.md` (only if Task 5 moved keys)

**Interfaces:**
- Consumes: the plugin repo at a pinned commit.
- Produces: feature `flake.modules.nixos.pantheon-paper` (key `"modules/desktop/pantheon-paper"`), option `constellation.desktop.paper.enable` (bool, default `config.constellation.desktop.variant == "pantheon"`).

`package.nix`: modelled on `packages/pantheon-global-menu/package.nix` — `fetchFromGitHub` pinned rev and hash, `nativeBuildInputs` meson ninja pkg-config vala glib (for `glib-compile-schemas`), `wrapGAppsNoGuiHook` not needed; `buildInputs` glib libgee gala and the `findFirst` mutter; `doCheck = true` (meson test). The module, under `lib.mkIf (pantheon enabled && cfg.enable)`: adds the package to `environment.systemPackages` (plugin and schema), and sets dconf through `programs.dconf.profiles` the same way `desktop.nix` writes Pantheon's other defaults: `org/gnome/mutter` `edge-tiling = false`; `org/gnome/mutter/keybindings` `toggle-tiled-left = []`, `toggle-tiled-right = []`; `org/gnome/desktop/wm/keybindings` `maximize = []`, `unmaximize = []`, `toggle-maximized = []`. Header comment as in `pantheon-globalmenu.nix`: plugin dir, next-login activation, crash ends the session, the bindings it clears and why.

- [ ] **Step 1: Bump the package, write the module, `git add` them.**
- [ ] **Step 2: Build the package** (runs the unit tests): `nix build --impure --expr '(builtins.getFlake (toString ./.)).nixosConfigurations.raider.pkgs.callPackage ./packages/pantheon-paper/package.nix {}'`. Expected: success, with `lib/gala/plugins/libgala-paper.so` and `share/glib-2.0/schemas/io.github.arsfeld.paper.keybindings.gschema.xml` in the output.
- [ ] **Step 3: Build raider** — `nix build .#nixosConfigurations.raider.config.system.build.toplevel` (alone, niced). Expected: success. Then blackbird the same way, after raider finishes.
- [ ] **Step 4: Verify dconf defaults in the built system**: grep the generated dconf profile/keyfile in the toplevel for `edge-tiling=false` and `toggle-tiled-left=@as []`.
- [ ] **Step 5: `just fmt`, update CLAUDE.md, commit** `feat(modules): PaperWM-style tiling in Pantheon (pantheon-paper)`.
- [ ] **Step 6: Hand over to the user** for `nix develop -c just test raider` (or deploy) and a logout/login, since Gala loads plugins only at startup and a login on raider is the user's to do. After their login, confirm `journalctl --user -b | grep pantheon-paper` shows the load line and take one `just pantheon::shot` of the live strip.
