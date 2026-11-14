# pantheon-paper Edge Margin and Edge Previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show that more columns lie beyond a screen edge: keep a margin so the real neighbour window peeks in, and preview the hidden window when the pointer rests at the edge.

**Architecture:** The margin is pure layout math in `src/core/` (`Params`, `Layout.vala`), unit-tested. A new pure function `hidden_beyond` picks the column a preview shows. A new `src/EdgePreview.vala`, owned by the `Controller` like `FocusRing`, watches the pointer and shows a `Clutter.Clone`. Two new GSettings keys reach the plugin through `Config` and are edited in the Tiling page and the indicator.

**Tech Stack:** Vala, Mutter 46/48 (libmutter-14/16), Clutter, Gala plugin API, GSettings, meson. GTK 4 (plug), GTK 3 (indicator).

**Spec:** `docs/superpowers/specs/2026-11-14-pantheon-paper-edge-peek-design.md` (this repo). Read it first.

**Repos:** Tasks 1–4 are in the plugin checkout `~/Code/pantheon-paper` (commit to its `master`, conventional `type: subject` with no scope, as its log does, and push at the end of Task 4). Task 5 is in `~/Code/nixos` (commit to `master`; never branch).

**Build and test (plugin checkout, from `~/Code/pantheon-paper`):**
`just -f ~/Code/nixos/justfile pantheon::paper-shell bash -c 'meson setup build --reconfigure; ninja -C build && meson test -C build --print-errorlogs'`
(abbreviated below as **BUILD+TEST**; a single suite: append the suite name, e.g. `meson test -C build layout`).

## Global Constraints

- `margin`: GSettings int, range 0–100, default 20, logical px. `edge-preview`: bool, default true. Schema `io.github.arsfeld.paper`.
- With `margin = 0` the layout is exactly today's, except that a column wider than the usable width is centred instead of left-aligned.
- Preset width: `round (U × f) − gap`, where `U = work.width − 2 × margin` (today's `Params.pixels` formula applied to `U`). Full width (Super+M) is `U`.
- Edge preview: arms within 2 px of a screen-end edge of the primary monitor's work area, never at an edge that borders another monitor; shows after 100 ms; clone at 15% scale; flush against the edge, vertically centred on the pointer, clamped to the work area; non-reactive; in `wm.top_window_group`; fades over `ANIM_MS` when animations are on.
- A Mutter call that differs between Mutter 46 and 48 goes in `src/Compat.vala`, never inline (CI builds both).
- Never test by logging into a session with a new build; use the headless Gala (`paper-run`). Never put the headless command line literally in a shell command of your own (`paper-stop` `pkill -f`s it).
- `debian/pantheon-paper.gschema.override` does not change.

## Review Focus

1. **A margin too large for the work area** (100 px on a narrow or portrait monitor): `U` must never go below `work.width / 2`, or columns get tiny or negative widths. → Task 1 test `margin_never_eats_half_the_screen`.
2. **Changing `margin` live** while a column is focused near an edge: the focused column should end up inside the new margin lines, not left where the old scroll put it. → Task 2 demo step `margin-60` asserted in its verification step.
3. **The previewed window closes or is focused while its preview is up**: the clone must vanish, never show a dead or now-visible window. → Task 4 verification (click at the edge; the preview is `none` afterwards), and the destroy handler in Task 4 Step 3.
4. **Dragging a window to the screen edge** (a grab in progress): no preview may appear over the drag. → Task 4 verification step with `down`/`move`/`up`.
5. **Fullscreen or the multitasking view with the pointer at the edge**: no preview. → Task 4 Step 3 guards (`fullscreen`, `wm.is_modal ()`), checked by hand in Task 6.

---

### Task 1: The margin in the layout core

**Files:**
- Modify: `src/core/Params.vala` (add `margin`, `usable`, route `pixels` through it)
- Modify: `src/core/Layout.vala` (`column_width`, `layout`, `scroll_to_focus`, `center_focus`)
- Test: `tests/test_layout.vala`

**Interfaces:**
- Produces: `Params.margin` (`public int margin = 0;` — default 0 in the core so every existing test keeps meaning margin 0; the Controller sets it from settings in Task 2); `public int Params.usable (int work_width)` returning `int.max (work_width - 2 * margin, work_width / 2)`; `Params.pixels (int preset, int work_width)` keeps its signature and now uses `usable (work_width)` in place of `work_width`. Callers (`Strip.cycle_width`, `column_width`) are unchanged.

- [ ] **Step 1: Write the failing tests** in `tests/test_layout.vala` (margin 20 via `s.params.margin = 20`; `WORK = {0, 32, 1920, 1048}`, gap 8, so `U = 1880`, a half is 932, the column stride is 940):

```vala
Strip margined (int n) { var s = strip_of (n); s.params.margin = 20; return s; }

Test.add_func ("/layout/margin_halves", () => {
    var r = layout (margined (2), WORK, new NoHints ());
    assert (at (r, 1).rect.x == 20 && at (r, 1).rect.width == 932);
    assert (at (r, 2).rect.x == 960 && at (r, 2).rect.width == 932);
});
Test.add_func ("/layout/margin_full_width", () => {
    var s = margined (2); s.focus (1); s.toggle_full ();
    var r = layout (s, WORK, new NoHints ());
    assert (at (r, 1).rect.x == 20 && at (r, 1).rect.width == 1880);
});
Test.add_func ("/layout/margin_scroll_to_focus_peeks", () => {
    var s = margined (4); s.focus (3);
    scroll_to_focus (s, WORK, new NoHints ());
    assert (s.scroll_x == 932);
    var r = layout (s, WORK, new NoHints ());
    assert (at (r, 3).rect.x + at (r, 3).rect.width == 1900); // 20 px short of the edge
    assert (at (r, 4).parked && at (r, 4).rect.x == 1845);    // its last 20 px show
    s.focus (1);
    scroll_to_focus (s, WORK, new NoHints ());
    assert (s.scroll_x == 0 && layout (s, WORK, new NoHints ()).windows[0].rect.x == 20);
});
Test.add_func ("/layout/margin_center_focus", () => {
    var s = margined (3); s.focus (2);
    center_focus (s, WORK, new NoHints ());
    assert (s.scroll_x == 466 && at (layout (s, WORK, new NoHints ()), 2).rect.x == 494);
});
Test.add_func ("/layout/margin_walled_right_peeks", () => {
    var r = layout (margined (3), WORK, new NoHints (), false, true);
    assert (at (r, 3).parked && at (r, 3).rect.x == 988); // flush with the wall, under column 2 (ends 1892)
});
Test.add_func ("/layout/margin_never_eats_half_the_screen", () => {
    var s = strip_of (1); s.params.margin = 100;
    Rect narrow = { 0, 0, 300, 800 };
    assert (s.params.usable (300) == 150);
    assert (layout (s, narrow, new NoHints ()).windows[0].rect.width == 67); // round (150 × 0.5) − 8
});
```

Also rename `/layout/scroll_to_focus_wide_column_left_aligns` to `/layout/scroll_to_focus_wide_column_centres` and change its assertion to `assert (s.scroll_x == 1250);` (column 2: left 960, width 2500, centred at x −290).

- [ ] **Step 2: Run to verify they fail.** BUILD+TEST, suite `layout`. Expected: FAIL (`usable` undefined, then wrong positions).

- [ ] **Step 3: Implement.**
  - `Params`: `margin`, `usable`, and `pixels` using `usable`.
  - `column_width`: full is `p.usable (work.width)`.
  - `layout`: a column's x is `work.x + s.params.margin + left - s.scroll_x`. Parking stays measured against `work.x` / `work.x + work.width`.
  - `scroll_to_focus`, with `m = margin` and `U = usable`:
    - `width >= U`: `scroll_x = m + left - (work.width - width) / 2` (centre)
    - else if `left < scroll_x`: `scroll_x = left`
    - else if `left + width > scroll_x + U`: `scroll_x = left + width - U`
  - `center_focus`: `scroll_x = m + left + width / 2 - work.width / 2`.
  - `pan` is unchanged.
  - Update the doc comments: "left-aligned if too wide" → "centred if too wide".

- [ ] **Step 4: Run to verify.** BUILD+TEST (all suites). Expected: all pass, including every pre-existing layout, strip and drop test unchanged (they run at margin 0).

- [ ] **Step 5: Commit.** `git add src/core tests/test_layout.vala && git commit -m "feat: a margin between the strip and the screen edges, where the neighbour peeks in"`

---

### Task 2: The `margin` and `edge-preview` settings

**Files:**
- Modify: `data/io.github.arsfeld.paper.gschema.xml`, `src/Config.vala`, `src/Controller.vala` (`refresh_params`, `on_config_changed`), `src/Demo.vala` (`add_settings_steps`), `plug/LayoutPage.vala`, `indicator/Popover.vala`, `README.md`
- Test: BUILD+TEST (the `schemas` suite compiles the keys strictly; the indicator and plug model suites load the schema); headless settings demo

**Interfaces:**
- Consumes: `Params.margin` (Task 1).
- Produces: `Config.margin` (`int`, default 20) and `Config.edge_preview` (`bool`, default true), both live with `changed (key)`; `Controller.params.margin` follows `config.margin`.

- [ ] **Step 1: Schema.** Add after `gap`:

```xml
<key name="margin" type="i">
  <range min="0" max="100"/>
  <default>20</default>
  <summary>Space between a focused column and the screen edge, where the next window peeks in, in logical pixels</summary>
</key>
```

and after `focus-ring`:

```xml
<key name="edge-preview" type="b">
  <default>true</default>
  <summary>Show a thumbnail of the hidden window when the pointer rests at a screen edge</summary>
</key>
```

- [ ] **Step 2: Config and Controller.**
  - `Config`: add both properties, add both keys to the construct-time `load` list, and add a case for each in `load`.
  - `refresh_params`: `@params.margin = config.margin;`.
  - `on_config_changed`, for `"margin"`: for every strip, `scroll_to_focus (strip, work_area_of (ws), this)` before the trailing `relayout ()`. This is Review Focus 2.
  - `on_config_changed`, for `"edge-preview"`: call `preview.refresh ()` and return. Until Task 4 adds the `preview` field, make it a bare `return`.

- [ ] **Step 3: UI.**
  - `plug/LayoutPage.vala`: a `margin` spin button, 0–100, wired exactly like `gap` (`value_changed` and `settings.changed["margin"]`). Add the row `"Margin at screen edges"` / `"Where the next window peeks in; 0 for none"` after the Gap row, and a switch row `"Edge previews"` / `"A thumbnail of the hidden window when the pointer rests at a screen edge"` bound to `edge-preview` after Focus ring. Renumber the rows.
  - `indicator/Popover.vala`: a `Margin` scale, 0–100, built like `gap` and `settings.bind`-ed, packed after the gap row. Update the class doc comment's list.

- [ ] **Step 4: Demo steps.** In `add_settings_steps`, after `gap-24`, add `margin-60` (`set_int ("margin", 60)`) and `margin-20`.

- [ ] **Step 5: README.** In the settings list, document `margin` and `edge-preview` with their defaults, one line each.

- [ ] **Step 6: Run.** BUILD+TEST. Expected: all pass. The `schemas` suite compiles the new keys `--strict`.

- [ ] **Step 7: Headless check (Review Focus 2).**
  1. `ninja -C build && just -f ~/Code/nixos/justfile pantheon::paper-run build PAPER_DEMO=3 PAPER_DEMO_SETTINGS=1`
  2. Wait for the log to reach `margin-20`.
  3. `grep 'paper-demo: at .* margin-' /tmp/paper-gala.log`

  Expected: the `margin-60` line shows the focused (`*`) window's frame wholly within x ∈ [60, 1860], and the `margin-20` line within [20, 1900]. `pantheon::paper-stop` afterwards.

- [ ] **Step 8: Commit.** `git commit -am "feat: margin and edge-preview settings, in the Tiling page and the indicator"`

---

### Task 3: `hidden_beyond`

**Files:**
- Modify: `src/core/Layout.vala`, `src/core/Strip.vala`
- Test: `tests/test_layout.vala`

**Interfaces:**
- Produces:
  - `public enum Paper.Side { LEFT, RIGHT }`.
  - `public int hidden_beyond (LayoutResult r, Rect work, Side side)`: the index into `r.columns` of the column nearest the visible area on `side` that is parked or whose centre lies beyond that edge, or −1. For RIGHT that is the lowest such index; for LEFT, the highest. A column counts as parked if any of its windows' `Placement.parked` is set. Add a parallel `Gee.ArrayList<bool> parked` to `LayoutResult`, one per column, filled in `layout`, rather than walking `windows`.
  - `Strip.active_window (Column col)` made `public`.

- [ ] **Step 1: Write the failing tests** (`margined` from Task 1):

```vala
Test.add_func ("/layout/hidden_beyond_ends", () => {
    var s = margined (4); s.focus (3); scroll_to_focus (s, WORK, new NoHints ());
    var r = layout (s, WORK, new NoHints ());
    assert (hidden_beyond (r, WORK, Side.RIGHT) == 3);
    assert (hidden_beyond (r, WORK, Side.LEFT) == 0);
});
Test.add_func ("/layout/hidden_beyond_none_when_it_fits", () => {
    var r = layout (margined (2), WORK, new NoHints ());
    assert (hidden_beyond (r, WORK, Side.LEFT) == -1 && hidden_beyond (r, WORK, Side.RIGHT) == -1);
});
Test.add_func ("/layout/hidden_beyond_walled_parked_counts", () => {
    var r = layout (margined (3), WORK, new NoHints (), false, true);
    assert (hidden_beyond (r, WORK, Side.RIGHT) == 2); // parked at 988, centre on screen
});
Test.add_func ("/layout/hidden_beyond_straddler", () => {
    var s = strip_of (3); s.scroll_x = 400; // column 3 at 1520, width 952: centre 1996 > 1920
    var r = layout (s, WORK, new NoHints ());
    assert (hidden_beyond (r, WORK, Side.RIGHT) == 2 && hidden_beyond (r, WORK, Side.LEFT) == -1);
});
```

- [ ] **Step 2: Run to verify they fail.** BUILD+TEST, suite `layout`. Expected: compile failure on `hidden_beyond`.
- [ ] **Step 3: Implement** `Side`, `LayoutResult.parked`, `hidden_beyond`, and make `active_window` public.
- [ ] **Step 4: Run.** BUILD+TEST. Expected: all pass.
- [ ] **Step 5: Commit.** `git commit -am "feat: hidden_beyond, the column a screen edge hides"`

---

### Task 4: `EdgePreview`

**Files:**
- Create: `src/EdgePreview.vala` (and add it to `plugin_sources` in `src/meson.build`)
- Modify: `src/Compat.vala`, `src/Controller.vala`
- Test: headless Gala with `tests/inject.py` (via `paper-inject`)

**Interfaces:**
- Consumes:
  - `hidden_beyond`, `Side` and `Strip.active_window` (Task 3)
  - `Config.edge_preview` (Task 2)
  - `Controller.current_strip ()`, `layout_of (Strip)`, `work_area ()`, `walls (out bool, out bool)`, `window_for (uint64)`, `workspace_tiled (Meta.Workspace)`, `animations_enabled ()`
- Produces:
  - `public Meta.CursorTracker Paper.cursor_tracker (Meta.Display)` in `Compat.vala`, split on `HAS_MUTTER48` the way `pointer` is.
  - `public class EdgePreview : Object`:
    - `EdgePreview (Gala.WindowManager wm, Controller c)`
    - `void refresh ()`: re-evaluates against the current pointer position.
    - `void destroy ()`
    - `string describe ()`: `"none"`, or `"<left|right> <title> @x,y wxh"` for the clone's transformed extents, in the same format as `FocusRing.describe`.
  - The Controller adds a `preview` field and appends `" || preview: " + preview.describe ()` to `describe ()`. Update that method's doc comment.

- [ ] **Step 1: Compat.** Add `cursor_tracker` (Mutter 48: `display.get_context ().get_backend ().get_cursor_tracker ()`; 46: `display.get_cursor_tracker ()`). Make `pointer` use it.

- [ ] **Step 2: Write `EdgePreview`.**
  - **Pointer:** connect `cursor_tracker (display).position_invalidated` to `refresh`, and read the position with `Paper.pointer`.
  - **Arming:** `refresh ()` arms a side when the pointer's y lies within `work_area ()` and its x is within 2 px of that side's edge. The side must not be a wall per `walls`. It also needs all of the following:
    - `config.edge_preview` is on;
    - the current workspace is tiled;
    - the focused window is not fullscreen;
    - `!wm.is_modal ()`;
    - no grab is active: track `display.grab_op_begin` / `grab_op_end` in a bool, and hide on begin;
    - `hidden_beyond (c.layout_of (strip), work, side) >= 0`.
  - **Showing:** once armed, start a 100 ms `Timeout`. If the pointer moves more than 2 px off the edge before it fires, cancel it. When it fires, build the clone:
    - `new Clutter.Clone (actor)`, scaled 0.15, `reactive = false`;
    - added to `wm.top_window_group`;
    - x flush with the edge (`work.x`, or `work.x + work.width − scaled width`);
    - y equal to pointer y minus half the scaled height, clamped to the work area;
    - opacity eased 0→255 over `ANIM_MS` when `c.animations_enabled ()`.
  - **Hiding:** any failed condition on a later `refresh` drops the clone. So does a change in which window is the target, and so does the target actor's `destroy`, connected the way `FocusRing.attach` does it.
  - **Fallback:** if the headless check in Step 4 shows `position_invalidated` does not fire on pointer motion, replace it with a 100 ms `Timeout` that polls `Paper.pointer` while `config.enabled`, and note why in the class comment.

- [ ] **Step 3: Controller wiring.** Construct `preview = new EdgePreview (wm, this)` next to `ring`. Destroy it in `destroy ()`. Call `preview.refresh ()` at the end of `relayout ()`, after `refresh_ring ()`, which covers a workspace switch, a focus change and the click. Replace Task 2's placeholder `"edge-preview"` branch with `preview.refresh (); return;`.

- [ ] **Step 4: Headless verification.**
  1. `ninja -C build && just -f ~/Code/nixos/justfile pantheon::paper-run build PAPER_DEMO=4 PAPER_DEMO_IDLE=1`
  2. Inject:
     - `move:5000,0` pushes the pointer to the right edge (it clamps there).
     - Wait 0.5 s, then `just pantheon::paper-shot /tmp/claude-…/scratchpad/preview.png`.
     - `down up` clicks at the edge.
     - `move:-400,0` moves off the edge.
     - Then `move:400,0 down move:-20,0 move:40,0` (a held drag back at the edge), then `up`.
  3. Read the `paper-demo: at` / settle lines in `/tmp/paper-gala.log`.

  Expected:
  - After the push, `|| preview: right <title of the first parked column's window> @…`, with the clone's right edge at 1920 and a width of about 15% of the window's.
  - The shot shows the thumbnail at the edge.
  - After the click, that window is `*` focused, scrolled inside the margin lines, and `|| preview: none`.
  - During the drag, `|| preview: none`.

  Then `paper-stop`. Also run `PAPER_MONITORS=2`, push the pointer right *into* the second monitor's side of the shared edge and back, and expect `|| preview: none` throughout, while the parked column's last 20 px appear in a shot at x 1900–1920.

- [ ] **Step 5: Run.** BUILD+TEST. Expected: all pass (unit suites unaffected).

- [ ] **Step 6: README.** One short paragraph in the README's layout section on what the margin and edge previews do.

- [ ] **Step 7: Commit and push.** `git add src README.md && git commit -m "feat: edge previews: a thumbnail of the hidden window at a screen edge" && git push`

---

### Task 5: Pin in nixos, docs, deploy check

**Files:**
- Modify: `~/Code/nixos/packages/pantheon-paper/package.nix` (`rev`, `hash`, `version`)
- Modify: `~/Code/nixos/CLAUDE.md` ("Pantheon tiling" section)

- [ ] **Step 1: Pin.** Set `rev` to the pushed plugin HEAD and `version = "0-unstable-<today>"`. Get the hash with `nix-prefetch-github arsfeld pantheon-paper --rev <rev>`, or set `lib.fakeHash`, build, and copy the reported hash.
- [ ] **Step 2: Build.** `nix build .#nixosConfigurations.raider.config.system.build.toplevel` (one host only, niced; the package's `checkPhase` runs the unit suites). Expected: success.
- [ ] **Step 3: Docs.** In CLAUDE.md's "Pantheon tiling" paragraph, after "Super+scroll pans…", add one sentence: the strip keeps a `margin` (20 px) from each screen edge where the next window peeks in, and resting the pointer at an edge previews the hidden window, clicking focuses it. Add `margin` and `edge preview` to the list of settings in `io.github.arsfeld.paper`, and `|| preview:` next to `|| ring:` in the demo-log sentence.
- [ ] **Step 4: Commit.** `git add packages/pantheon-paper CLAUDE.md && git commit -m "chore(modules): pin pantheon-paper with edge margin and edge previews"`
- [ ] **Step 5: Deploy and check by hand (ask before deploying).** `nix develop -c just deploy raider`, then log out and in. Check:
  - the 20 px peek at both ends of a strip;
  - the Margin slider in the indicator and on the Tiling page, live;
  - the Edge previews switch;
  - the hover preview and click at both edges;
  - no preview in fullscreen or the multitasking view (Review Focus 5).
