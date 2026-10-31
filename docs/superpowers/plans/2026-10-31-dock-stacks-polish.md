# Dock Stacks Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Downloads dock tile a macOS-style pile, give a clicked fan item visible feedback (zoom, collapse, tile bounce), and draw the tilted fan rows without jagged edges.

**Architecture:** All new code is Vala under `modules/constellation/pantheon-dock/stacks/src/`, copied into the dock's `src/Stacks/` by the overlay in `modules/constellation/pantheon-dock/default.nix`. The fan's geometry moves into a display-free `FanMath` namespace so the unit test can cover it. A shared `StackRender.append_supersampled` paints tilted widgets through a 2× texture. `StackPile` is a new tile widget. `StackSource` gains a `launched` signal that both popovers emit and `StackItem` answers with a bounce.

**Tech Stack:** Vala, GTK 4.22 (GSK, `Gtk.WidgetPaintable`), libadwaita (`Adw.TimedAnimation`), GLib.Test, meson; Nix (NixOS module option, NixOS VM test).

Spec: `docs/superpowers/specs/2026-10-31-dock-stacks-polish-design.md`. Read
`modules/constellation/pantheon-dock/CLAUDE.md` before starting: it holds the visual loop,
the Vala pitfalls that bit this code before, and the deploy order.

## Global Constraints

- `display` values are exactly `stack | grid | folder`; the default stays `"stack"`.
- `stack` = the new pile; `grid` = today's `BaseIconGroup` 2×2 preview; `folder` = unchanged.
- An empty or missing source always shows the folder icon, whatever `display` says.
- A click opens the file **immediately**; opening never waits on an animation.
- Launch animation: 250 ms, ease-out; the clicked icon grows to 1.6× and fades out.
- Bounce: up 200 ms `EASE_IN_OUT_QUAD` to half the overlay height, down 600 ms `EASE_OUT_BOUNCE`, played once per launch.
- Supersampling factor: 2× the surface scale, filtered with `Gsk.ScalingFilter.TRILINEAR`.
- Never inject input to test; use the `DOCK_STACKS_OPEN` / `DOCK_STACKS_CLICK` hooks.
- Signal handlers on long-lived objects are methods, not capturing lambdas; anything connected in `StackItem` is disconnected in its `teardown ()`.
- Commit straight to master (no branches, no worktrees). Conventional commits, scope `modules` for the shared module, `raider`/`blackbird` for host files. Never mention Claude.
- Run `just fmt` before committing any `.nix` change.
- New files are invisible to `nix build` until `git add`ed: `git add -N <path>` first.
- **`zoom/hooks.patch` may hold another session's uncommitted work.** Never stage or commit it, except for the one context line in Task 7. Every build below uses the working tree, so a broken in-progress zoom patch makes the dock build fail; if that happens, stop and ask the user rather than touching zoom.

## File Structure

```
modules/constellation/pantheon-dock/
  default.nix                       display enum gains "grid"
  CLAUDE.md                         documents the DOCK_STACKS_CLICK hook
  stacks/hooks.patch                schema description mentions 'grid'
  zoom/hooks.patch                  same line, as context only (Task 7)
  stacks/src/
    meson.build                     + FanMath.vala (core), StackPile.vala, StackRender.vala
    StackConfig.vala                Display.GRID, parses "grid"
    StackSource.vala                + signal launched ()
    FanMath.vala          (new)     fan geometry and launch poses; no widgets
    StackRender.vala      (new)     append_supersampled (): paint a widget via a 2× texture
    StackPile.vala        (new)     the pile tile
    FanLayout.vala                  uses FanMath; collapse; supersampled tilted rows; ghost icon
    FanPopover.vala                 launch animation, launch_for_test ()
    GridPopover.vala                emits source.launched
    StackItem.vala                  pile/grid/folder choice, bounce, DOCK_STACKS_CLICK
    tests/StackTests.vala           grid parsing, FanMath poses
hosts/raider/configuration.nix      Applications: display = "grid"
hosts/blackbird/configuration.nix   Applications: display = "grid"
tests/pantheon-dock-test.nix Applications: display = "grid"
docs/superpowers/specs/2026-10-31-dock-stacks-polish-design.md   two wording fixes (Task 7)
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
S=/tmp/claude-1000/-home-arosenfeld-Code-nixos/dock-polish && mkdir -p "$S"
just pantheon::dock-run "$S/dock.log" DOCK_STACKS_OPEN=0     # 0 = Downloads, the first stack
just pantheon::shot "$S/fan.png" 1000 300 1500 1140          # fan area, physical px
just pantheon::shot "$S/tile.png" 1500 1240 600 200          # dock tiles close up
```

Read the PNGs with the Read tool. When finished, hand the session back to the stock dock:
`pkill -f '(^|/)io\.elementary\.dock$'` (the session respawns it).

---

### Task 1: Confirm the cause of the jagged rows

Diagnosis only: no code, no commit. It decides nothing by itself; Task 3 is the fix either way.

**Files:** none.

- [ ] **Step 1: Capture the fan under each GSK renderer**

```bash
cd /home/arosenfeld/Code/nixos
S=/tmp/claude-1000/-home-arosenfeld-Code-nixos/dock-polish && mkdir -p "$S"
just pantheon::dock-run "$S/dock-default.log" DOCK_STACKS_OPEN=0
```

Wait about 3 s for the fan to open, then:

```bash
just pantheon::shot "$S/fan-default.png" 1000 300 1500 1140
```

Repeat the pair for each of `GSK_RENDERER=ngl`, `GSK_RENDERER=vulkan`, `GSK_RENDERER=gl` and
`GSK_RENDERER=cairo`, passing it as an extra argument to `dock-run`
(`just pantheon::dock-run "$S/dock-ngl.log" DOCK_STACKS_OPEN=0 GSK_RENDERER=ngl`) and naming
the shot `fan-<renderer>.png`.

- [ ] **Step 2: Compare**

Read every PNG. Look at the top rows (the most tilted): pill edges and label text. Write one
line per renderer into `$S/renderers.txt` (clean / jagged / broken). Expected: jagged under
the default, confirming the rotation path. Also note which renderer the default resolves
to, if `$S/dock-default.log` says.

- [ ] **Step 3: Restore the stock dock**

```bash
pkill -f '(^|/)io\.elementary\.dock$'
```

Report the table to the reviewer. Continue to Task 2 whatever it shows.

---

### Task 2: `grid` display value

After this task `grid` and `stack` both still draw the 2×2 preview; Task 4 turns `stack`
into the pile. Applications switches to `grid` now so nothing changes on screen later.

**Files:**
- Modify: `modules/constellation/pantheon-dock/stacks/src/StackConfig.vala`
- Modify: `modules/constellation/pantheon-dock/stacks/src/StackItem.vala` (`update_child`)
- Modify: `modules/constellation/pantheon-dock/stacks/src/tests/StackTests.vala`
- Modify: `modules/constellation/pantheon-dock/default.nix` (the `display` option)
- Modify: `hosts/raider/configuration.nix:106`, `hosts/blackbird/configuration.nix:95`
- Modify: `tests/pantheon-dock-test.nix` (the `applications` stack)

**Interfaces:**
- Produces: `StackConfig.Display { STACK, GRID, FOLDER }`; `StackConfig.parse (…, "grid")` returns `display == GRID`.

- [ ] **Step 1: Write the failing test**

In `StackTests.vala`, add after `test_parse_applications`:

```vala
void test_parse_display_grid () {
    try {
        var config = StackConfig.parse ("applications", "grid", "name", "grid");
        assert_true (config.display == StackConfig.Display.GRID);
    } catch (StackConfigError e) {
        error ("unexpected error: %s", e.message);
    }
}
```

and register it in `main` after the `/stack-config/applications` line:

```vala
    Test.add_func ("/stack-config/display-grid", test_parse_display_grid);
```

- [ ] **Step 2: Run it to make sure it fails**

Run the dock build from the development loop.
Expected: the build fails in the check phase, with `/stack-config/display-grid` reporting
`unexpected error: unknown display 'grid'`. (If valac instead fails on `Display.GRID` not
existing, that is the same failure, one stage earlier.)

- [ ] **Step 3: Implement**

`StackConfig.vala`: change the enum to

```vala
    public enum Display { STACK, GRID, FOLDER }
```

and add the case to `parse`'s display switch:

```vala
            case "stack": parsed_display = STACK; break;
            case "grid": parsed_display = GRID; break;
            case "folder": parsed_display = FOLDER; break;
```

`StackItem.vala`: replace the body of `update_child` with

```vala
    private void update_child () {
        var empty = source.missing || source.entries.get_n_items () == 0;
        Gtk.Widget wanted;
        if (empty || config.display == FOLDER) {
            wanted = folder_image;
        } else {
            wanted = preview;
        }
        if (child != wanted) {
            child = wanted;
        }
        folder_image.opacity = source.missing ? 0.5 : 1.0;
    }
```

`default.nix`: the display option becomes

```nix
          display = lib.mkOption {
            type = lib.types.enum ["stack" "grid" "folder"];
            default = "stack";
            description = "stack: a pile of the newest entries; grid: a 2×2 preview; folder: a static icon.";
          };
```

`hosts/raider/configuration.nix` and `hosts/blackbird/configuration.nix`: the Applications
entry `{source = "applications";}` becomes

```nix
        {
          source = "applications";
          display = "grid";
        }
```

`tests/pantheon-dock-test.nix`: the same change to its `{source = "applications";}`.

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd /home/arosenfeld/Code/nixos && just fmt
nix build --no-link -L .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock 2>&1 | tail -n 30
nix eval --json .#nixosConfigurations.raider.config.constellation.desktop.pantheon.dockStacks
```

Expected: build succeeds with `stacks` test OK; the eval shows Applications with `"display":"grid"`.

- [ ] **Step 5: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src/StackConfig.vala \
  modules/constellation/pantheon-dock/stacks/src/StackItem.vala \
  modules/constellation/pantheon-dock/stacks/src/tests/StackTests.vala \
  modules/constellation/pantheon-dock/default.nix \
  hosts/raider/configuration.nix hosts/blackbird/configuration.nix \
  tests/pantheon-dock-test.nix
git commit -m "feat(modules): add a grid display value for dock stacks"
```

---

### Task 3: Smooth tilted fan rows (`FanMath`, `StackRender`)

**Files:**
- Create: `modules/constellation/pantheon-dock/stacks/src/FanMath.vala`
- Create: `modules/constellation/pantheon-dock/stacks/src/StackRender.vala`
- Modify: `modules/constellation/pantheon-dock/stacks/src/FanLayout.vala` (rewritten below)
- Modify: `modules/constellation/pantheon-dock/stacks/src/FanPopover.vala` (`MAX_ITEMS` only)
- Modify: `modules/constellation/pantheon-dock/stacks/src/meson.build`
- Modify: `modules/constellation/pantheon-dock/stacks/src/tests/StackTests.vala`

**Interfaces:**
- Produces: `namespace Dock.FanMath` with `const int MAX_ITEMS = 10`, `const int ICON_SIZE = 48`, `const int ROW_HEIGHT = 56`, `const double ZOOM = 0.6`, `struct Pose { double x; double y; double degrees; double alpha; }`, `double drift (uint i)`, `double degrees (uint i)`, `Pose pose (uint i, double collapse, bool clicked)`, `double ghost_scale (double collapse)`.
- Produces: `Dock.StackRender.append_supersampled (Gtk.Snapshot snapshot, Gtk.Widget widget, Gsk.Transform transform, float width, float height)`.
- Produces: `FanLayout.ICON_SIZE` (unchanged name, still used by `FanPopover`), and `FanLayout.collapse` (`double` property, 0 = open) — the collapse/ghost behaviour is wired in Task 5; here it only exists at 0.

- [ ] **Step 1: Write the failing tests**

In `StackTests.vala`, add before `int main`:

```vala
void assert_near (double actual, double expected) {
    if ((actual - expected).abs () > 1e-9) {
        error ("%g != %g", actual, expected);
    }
}

void test_fan_pose_open () {
    // The ends of the curve are the ones the fan was tuned to on screen.
    assert_near (FanMath.drift (0), 0);
    assert_near (FanMath.degrees (0), 0);
    assert_near (FanMath.drift (FanMath.MAX_ITEMS), 44);
    assert_near (FanMath.degrees (FanMath.MAX_ITEMS), 5);

    for (uint i = 0; i <= FanMath.MAX_ITEMS; i++) {
        foreach (var clicked in new bool[] { false, true }) {
            var pose = FanMath.pose (i, 0, clicked);
            assert_near (pose.x, FanMath.drift (i));
            assert_near (pose.y, -FanMath.ROW_HEIGHT * (i + 0.5));
            assert_near (pose.degrees, FanMath.degrees (i));
            assert_near (pose.alpha, 1);
        }
    }
}
```

and register it in `main` after the last `/stack-source/…` line:

```vala
    Test.add_func ("/fan-math/open", test_fan_pose_open);
```

- [ ] **Step 2: Run it to make sure it fails**

Run the dock build. Expected: valac error, `The name 'FanMath' does not exist in the context of …`.

- [ ] **Step 3: Implement**

Create `FanMath.vala`:

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The fan's geometry, kept free of widgets so the unit test can check it.
 * Positions are of a row's icon centre, measured from the bottom of the fan's
 * centre column; y grows downwards, so rows sit at negative y.
 */

namespace Dock.FanMath {
    public const int MAX_ITEMS = 10;
    public const int ICON_SIZE = 48;
    public const int ROW_HEIGHT = 56;
    // At the top of a full fan: the icon column's offset to the right, and the
    // row's tilt. Both grow from 0 at the bottom row.
    private const double MAX_DRIFT = 44;
    private const double MAX_DEGREES = 5;
    // Rows the curve is scaled for (the entries plus the "Open in Files" row),
    // so a short fan is the bottom of a full one rather than a squashed copy of it.
    private const int FULL_ROWS = MAX_ITEMS + 1;
    /* How much a clicked row's icon grows by the end of the launch animation. */
    public const double ZOOM = 0.6;

    public struct Pose {
        public double x;
        public double y;
        /* Clockwise tilt about the icon centre. */
        public double degrees;
        public double alpha;
    }

    private double progress (uint i) {
        return double.min (1.0, i / (double) (FULL_ROWS - 1));
    }

    /* Rightward drift of row i's icon: flat near the dock, growing with height. */
    public double drift (uint i) {
        var t = progress (i);
        return MAX_DRIFT * t * t;
    }

    /*
     * Row i's clockwise tilt, which lifts its label: the slope of the drift
     * curve, damped so even the top row tilts only a few degrees.
     */
    public double degrees (uint i) {
        return MAX_DEGREES * progress (i);
    }

    /*
     * Row i at a point of the launch animation (collapse 0 = open, 1 = done).
     * The clicked row stays put and fades, while its ghost icon zooms (see
     * ghost_scale); every other row slides down into row 0's slot, untilting
     * and fading, so the fan runs back into the dock tile.
     */
    public Pose pose (uint i, double collapse, bool clicked) {
        var open_y = -ROW_HEIGHT * (i + 0.5);
        Pose result;
        if (clicked) {
            result = { drift (i), open_y, degrees (i), 1 - collapse };
        } else {
            var keep = 1 - collapse;
            result = { drift (i) * keep, open_y * keep - ROW_HEIGHT * 0.5 * collapse, degrees (i) * keep, keep };
        }
        return result;
    }

    public double ghost_scale (double collapse) {
        return 1 + ZOOM * collapse;
    }
}
```

Create `StackRender.vala`:

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Painting a tilted widget cleanly. GSK draws rotated text and rounded clips
 * with jagged edges (see the 2026-10-31 dock stacks polish spec), so tilted
 * widgets are drawn upright into a texture at twice the surface scale, and the
 * texture is filtered as it is rotated and scaled back down.
 */

namespace Dock.StackRender {
    private const double OVERSAMPLE = 2;
    // Room for what a widget paints outside its allocation: the fan pills'
    // box-shadow and the icons' -gtk-icon-shadow (StackStyle).
    private const float PAD = 4;

    /*
     * Paints widget, of the given size, under transform. The caller must not
     * also snapshot_child () it.
     */
    public void append_supersampled (Gtk.Snapshot snapshot, Gtk.Widget widget, Gsk.Transform transform, float width, float height) {
        var native = widget.get_native ();
        if (native == null || width <= 0 || height <= 0) {
            return;
        }
        var scale = (float) (OVERSAMPLE * native.get_surface ().get_scale ());

        var inner = new Gtk.Snapshot ();
        inner.scale (scale, scale);
        inner.translate ({ PAD, PAD });
        new Gtk.WidgetPaintable (widget).snapshot (inner, width, height);
        var node = inner.to_node ();
        if (node == null) {
            return;
        }

        Graphene.Rect viewport = { { 0, 0 }, { (width + 2 * PAD) * scale, (height + 2 * PAD) * scale } };
        var texture = native.get_renderer ().render_texture (node, viewport);

        Graphene.Rect bounds = { { -PAD, -PAD }, { width + 2 * PAD, height + 2 * PAD } };
        snapshot.save ();
        snapshot.transform (transform);
        snapshot.append_scaled_texture (texture, TRILINEAR, bounds);
        snapshot.restore ();
    }
}
```

Replace `FanLayout.vala` entirely:

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Rows stacked bottom-up in one column, the way a macOS fan curves: row 0 sits
 * at the bottom, nearest the dock, and each row above it drifts a little
 * further right and tilts a little more (FanMath), so the column bends gently
 * to the right as it rises. Every row ends in an ICON_SIZE-wide icon, and the
 * icons form the column: it is centred horizontally, so the popover (which GTK
 * centres on the dock tile) puts the column right over the tile. The rows'
 * labels hang off to the left of it.
 *
 * Tilted rows are painted through StackRender, so their pills and text stay
 * smooth. Allocation still carries the real transform, so hover, clicks and
 * drags land where the row is drawn.
 */

public class Dock.FanLayout : Gtk.Widget {
    public const int ICON_SIZE = FanMath.ICON_SIZE;
    // Slack around the rows: 8 px so rotated corners never touch the popover
    // surface's edge, where they would be clipped, plus room for a clicked
    // row's icon to grow by ICON_SIZE * FanMath.ZOOM / 2 (about 15 px) a side.
    private const int MARGIN = 24;

    /* The launch animation's progress: 0 = open, 1 = folded into the tile. */
    public double collapse { get; set; default = 0; }

    private GenericArray<Gtk.Widget> rows = new GenericArray<Gtk.Widget> ();
    // From the last allocation, per row: what snapshot () paints with.
    private GenericArray<Gsk.Transform> transforms = new GenericArray<Gsk.Transform> ();
    private double[] tilts = {};
    private double[] alphas = {};

    construct {
        overflow = VISIBLE;
        notify["collapse"].connect (on_collapse_changed);
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

    private void on_collapse_changed () {
        queue_allocate ();
        queue_draw ();
    }

    public override Gtk.SizeRequestMode get_request_mode () {
        return CONSTANT_SIZE;
    }

    public override void measure (Gtk.Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
        minimum_baseline = natural_baseline = -1;

        double half_width, height;
        extent (out half_width, out height);
        minimum = natural = orientation == HORIZONTAL
            ? 2 * ((int) Math.ceil (half_width) + MARGIN)
            : (int) Math.ceil (height) + MARGIN;
    }

    public override void size_allocate (int width, int height, int baseline) {
        // Origin: the bottom of row 0, centred.
        float origin_x = width / 2.0f;
        float origin_y = height;

        transforms = new GenericArray<Gsk.Transform> ();
        tilts = new double[rows.length];
        alphas = new double[rows.length];

        for (uint i = 0; i < rows.length; i++) {
            var row = rows[i];
            var row_w = row_width (row);
            var pose = FanMath.pose (i, collapse, false);

            // Pivot on the icon's centre, so the icons stay in one column.
            var transform = new Gsk.Transform ()
                .translate ({ origin_x + (float) pose.x, origin_y + (float) pose.y })
                .rotate ((float) pose.degrees)
                .translate ({ -(row_w - ICON_SIZE / 2.0f), -FanMath.ROW_HEIGHT / 2.0f });
            transforms.add (transform);
            tilts[i] = pose.degrees;
            alphas[i] = pose.alpha;
            row.allocate (row_w, FanMath.ROW_HEIGHT, -1, transform);
        }
    }

    public override void snapshot (Gtk.Snapshot snapshot) {
        for (uint i = 0; i < rows.length; i++) {
            var row = rows[i];
            if (alphas[i] <= 0) {
                continue;
            }
            snapshot.push_opacity (alphas[i]);
            if (tilts[i] == 0) {
                snapshot_child (row, snapshot);
            } else {
                StackRender.append_supersampled (snapshot, row, transforms[i], row.get_width (), row.get_height ());
            }
            snapshot.pop ();
        }
    }

    /*
     * The bounds of all rows once rotated (in the open fan, which is the
     * largest), measured from the bottom of the centre column: half_width is
     * the larger reach to either side.
     */
    private void extent (out double half_width, out double height) {
        half_width = 0;
        height = 0;
        for (uint i = 0; i < rows.length; i++) {
            var row_w = row_width (rows[i]);
            var pose = FanMath.pose (i, 0, false);
            var radians = pose.degrees * Math.PI / 180.0;
            var cos_a = Math.cos (radians);
            var sin_a = Math.sin (radians);
            double[] xs = { -(row_w - ICON_SIZE / 2.0), ICON_SIZE / 2.0 };
            double[] ys = { -FanMath.ROW_HEIGHT / 2.0, FanMath.ROW_HEIGHT / 2.0 };
            foreach (var x in xs) {
                foreach (var y in ys) {
                    // Gsk rotates clockwise on screen; y grows downwards.
                    var px = pose.x + x * cos_a - y * sin_a;
                    var py = pose.y + x * sin_a + y * cos_a;
                    half_width = double.max (half_width, px.abs ());
                    height = double.max (height, -py);
                }
            }
        }
    }

    private static int row_width (Gtk.Widget row) {
        int min, nat, min_b, nat_b;
        row.measure (HORIZONTAL, -1, out min, out nat, out min_b, out nat_b);
        return nat;
    }
}
```

`FanPopover.vala`: change the constant to

```vala
    public const int MAX_ITEMS = FanMath.MAX_ITEMS;
```

`meson.build`: add `'FanMath.vala',` as the first entry of `stacks_core_sources`, and
`'StackRender.vala',` to the widget list after `'StackItem.vala',`. Extend the comment above
`stacks_core_sources`: `FanMath is core too: pure geometry, no widgets.`

- [ ] **Step 4: Run the tests and make sure they pass**

```bash
cd /home/arosenfeld/Code/nixos
git add -N modules/constellation/pantheon-dock/stacks/src/FanMath.vala modules/constellation/pantheon-dock/stacks/src/StackRender.vala
nix build --no-link -L .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock 2>&1 | tail -n 30
```

Expected: build succeeds; `/fan-math/open` passes.

- [ ] **Step 5: Look at it**

Run the development loop's `dock-run` with `DOCK_STACKS_OPEN=0` and shoot the fan area.
Compare with `fan-default.png` from Task 1. Check:
- the top rows' pill edges and label text are smooth;
- rows are not blurry compared with the untilted bottom row (a little softness is expected; mush is not);
- hovering is not testable without input — instead check `dock.log` has no `CRITICAL`/`WARNING`;
- the pill shadows are not cut off square at the row's edge.

If rows render blank, blurry, or with clipped shadows, try raising `PAD` and re-check once.
If it still looks wrong, take the **fallback** from the spec: delete `StackRender.vala`,
make `FanLayout.snapshot` always `snapshot_child` (keeping `push_opacity`), and set
`MAX_DEGREES = 0` in `FanMath` (update `test_fan_pose_open`'s expected 5 to 0). Report
which path was taken.

Restore the stock dock (`pkill …`) when done.

- [ ] **Step 6: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src/FanMath.vala \
  modules/constellation/pantheon-dock/stacks/src/StackRender.vala \
  modules/constellation/pantheon-dock/stacks/src/FanLayout.vala \
  modules/constellation/pantheon-dock/stacks/src/FanPopover.vala \
  modules/constellation/pantheon-dock/stacks/src/meson.build \
  modules/constellation/pantheon-dock/stacks/src/tests/StackTests.vala
git commit -m "fix(modules): draw the dock fan's tilted rows smoothly"
```

---

### Task 4: The pile tile (`StackPile`)

**Files:**
- Create: `modules/constellation/pantheon-dock/stacks/src/StackPile.vala`
- Modify: `modules/constellation/pantheon-dock/stacks/src/StackItem.vala`
- Modify: `modules/constellation/pantheon-dock/stacks/src/meson.build`

**Interfaces:**
- Consumes: `StackRender.append_supersampled` (Task 3), `StackConfig.Display.GRID` (Task 2).
- Produces: `Dock.StackPile (StackSource source)`, property `int icon_size`, method `void stop ()` (disconnects from the source; called by `StackItem.teardown`).

No unit test: the pile is a widget, and the core test runs without a display. It is
verified in the visual loop and the VM test.

- [ ] **Step 1: Create `StackPile.vala`**

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The dock tile of a `display = stack` stack: the newest entry's icon in front
 * and the next two peeking out behind it, tilted apart like a pile of papers,
 * as macOS draws "Display as Stack".
 */

public class Dock.StackPile : Gtk.Widget {
    // Per slot, front first: icon size and centre offset as fractions of the
    // tile (y grows downwards), and clockwise tilt in degrees. Tuned on screen.
    private const double[] SIZES = { 0.86, 0.76, 0.76 };
    private const double[] OFFSETS_X = { 0, -0.09, 0.10 };
    private const double[] OFFSETS_Y = { 0.05, -0.06, -0.08 };
    private const double[] DEGREES = { 0, -7, 6 };

    public StackSource source { get; construct; }
    public int icon_size { get; set; default = 48; }

    private GenericArray<Gtk.Image> images = new GenericArray<Gtk.Image> ();
    private GenericArray<Gsk.Transform> transforms = new GenericArray<Gsk.Transform> ();

    public StackPile (StackSource source) {
        Object (source: source);
    }

    construct {
        overflow = VISIBLE;
        halign = CENTER;
        valign = CENTER;

        for (int k = 0; k < SIZES.length; k++) {
            var image = new Gtk.Image ();
            image.set_parent (this);
            images.add (image);
        }

        // Methods, not lambdas: a closure over `this` held by the source would
        // keep the pile alive for as long as the source is.
        notify["icon-size"].connect (update_sizes);
        source.entries.items_changed.connect (update_icons);
        update_sizes ();
        update_icons ();
    }

    /* Called by StackItem.teardown (): stop following the source. */
    public void stop () {
        source.entries.items_changed.disconnect (update_icons);
    }

    public override void dispose () {
        foreach (var image in images) {
            image.unparent ();
        }
        images.length = 0;
        base.dispose ();
    }

    private int slot_size (int k) {
        return (int) Math.round (SIZES[k] * icon_size);
    }

    private void update_sizes () {
        for (int k = 0; k < images.length; k++) {
            images[k].pixel_size = slot_size (k);
        }
        queue_resize ();
    }

    private void update_icons () {
        var n = source.entries.get_n_items ();
        for (int k = 0; k < images.length; k++) {
            if (k < n) {
                images[k].gicon = ((StackEntry) source.entries.get_item (k)).icon;
                images[k].visible = true;
            } else {
                images[k].visible = false;
            }
        }
    }

    public override Gtk.SizeRequestMode get_request_mode () {
        return CONSTANT_SIZE;
    }

    public override void measure (Gtk.Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
        minimum = natural = icon_size;
        minimum_baseline = natural_baseline = -1;
    }

    public override void size_allocate (int width, int height, int baseline) {
        transforms = new GenericArray<Gsk.Transform> ();
        for (int k = 0; k < images.length; k++) {
            var size = slot_size (k);
            var transform = new Gsk.Transform ()
                .translate ({ (float) (width / 2.0 + OFFSETS_X[k] * icon_size), (float) (height / 2.0 + OFFSETS_Y[k] * icon_size) })
                .rotate ((float) DEGREES[k])
                .translate ({ -size / 2.0f, -size / 2.0f });
            transforms.add (transform);
            images[k].allocate (size, size, -1, transform);
        }
    }

    // Back to front, so the newest entry ends up on top.
    public override void snapshot (Gtk.Snapshot snapshot) {
        for (int k = images.length - 1; k >= 0; k--) {
            var image = images[k];
            if (!image.visible) {
                continue;
            }
            if (DEGREES[k] == 0) {
                snapshot_child (image, snapshot);
            } else {
                var size = slot_size (k);
                StackRender.append_supersampled (snapshot, image, transforms[k], size, size);
            }
        }
    }
}
```

If Task 3 took the fallback (no `StackRender`), set the two back slots' `DEGREES` to `0`
and drop the `else` branch, so every slot uses `snapshot_child`.

- [ ] **Step 2: Wire it into `StackItem`**

Add a field next to `folder_image`:

```vala
    private StackPile pile;
```

In `construct`, right after the `folder_image` binding:

```vala
        pile = new StackPile (source);
        bind_property ("icon-size", pile, "icon-size", SYNC_CREATE);
```

In `update_child`, replace the `if/else` that picks `wanted` with:

```vala
        Gtk.Widget wanted;
        if (empty || config.display == FOLDER) {
            wanted = folder_image;
        } else if (config.display == GRID) {
            wanted = preview;
        } else {
            wanted = pile;
        }
```

In `teardown`, after `source.entries.items_changed.disconnect (update_child);`:

```vala
        pile.stop ();
```

Update the class comment's first line to: `A folder stack on the dock: a pile of the newest
entries, a 2×2 preview, or a plain folder icon, opening as a fan or a grid.`

`meson.build`: add `'StackPile.vala',` to the widget list after `'StackItem.vala',`.

- [ ] **Step 3: Build**

```bash
cd /home/arosenfeld/Code/nixos
git add -N modules/constellation/pantheon-dock/stacks/src/StackPile.vala
nix build --no-link -L .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock 2>&1 | tail -n 30
```

Expected: success, all stacks tests pass.

- [ ] **Step 4: Look at it**

`just pantheon::dock-run "$S/dock.log" G_MESSAGES_DEBUG=all` (no open hook), then shoot the
tiles (`just pantheon::shot "$S/tile.png" 1500 1240 600 200`). Check:
- Downloads shows a pile: front icon upright, two tilted ones behind, nothing clipped by the tile;
- Applications still shows the 2×2 grid;
- edges of the tilted back icons are smooth.

Tune `SIZES`/`OFFSETS_*`/`DEGREES` if the pile looks cramped or spills out of the tile
background, re-shooting each time. Then run with `G_MESSAGES_DEBUG=all`, change `stacks`
by hand to force a teardown, and confirm `StackItem finalized` still appears in the log:

```bash
dock=$(nix build --no-link --print-out-paths .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock)
schemas=$(echo "$dock"/share/gsettings-schemas/*/glib-2.0/schemas)
GSETTINGS_SCHEMA_DIR="$schemas" gsettings set io.elementary.dock stacks "[('~/Downloads', 'fan', 'date-added', 'stack')]"
grep -E 'StackItem (teardown|finalized)' "$S/dock.log"
dconf reset /io/elementary/dock/stacks
```

Expected: a `teardown` and a `finalized` line for `applications`. Restore the stock dock.

- [ ] **Step 5: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src/StackPile.vala \
  modules/constellation/pantheon-dock/stacks/src/StackItem.vala \
  modules/constellation/pantheon-dock/stacks/src/meson.build
git commit -m "feat(modules): show dock stacks as a pile of their newest icons"
```

---

### Task 5: Launch animation in the fan

**Files:**
- Modify: `modules/constellation/pantheon-dock/stacks/src/FanLayout.vala`
- Modify: `modules/constellation/pantheon-dock/stacks/src/FanPopover.vala`
- Modify: `modules/constellation/pantheon-dock/stacks/src/StackSource.vala`
- Modify: `modules/constellation/pantheon-dock/stacks/src/StackItem.vala` (test hook only)
- Modify: `modules/constellation/pantheon-dock/stacks/src/tests/StackTests.vala`

**Interfaces:**
- Consumes: `FanMath.pose`, `FanMath.ghost_scale`, `StackRender.append_supersampled`.
- Produces: `StackSource.launched` (`signal void launched ()`), emitted when anything is opened from a popover; `FanLayout.start_launch (Gtk.Widget row, Gtk.Widget icon)`, `FanLayout.reset_launch ()`, `FanLayout.row_at (uint i) : Gtk.Widget?`; `FanPopover.launch_for_test (uint row, double progress)`.

- [ ] **Step 1: Write the failing test**

In `StackTests.vala`, after `test_fan_pose_open`:

```vala
void test_fan_pose_collapsed () {
    for (uint i = 0; i <= FanMath.MAX_ITEMS; i++) {
        // Every other row has folded into row 0's slot, upright and gone.
        var pose = FanMath.pose (i, 1, false);
        assert_near (pose.x, 0);
        assert_near (pose.y, -FanMath.ROW_HEIGHT * 0.5);
        assert_near (pose.degrees, 0);
        assert_near (pose.alpha, 0);

        // The clicked row stays where it was and fades.
        var clicked = FanMath.pose (i, 1, true);
        assert_near (clicked.x, FanMath.drift (i));
        assert_near (clicked.y, -FanMath.ROW_HEIGHT * (i + 0.5));
        assert_near (clicked.alpha, 0);
    }
    assert_near (FanMath.ghost_scale (0), 1);
    assert_near (FanMath.ghost_scale (1), 1.6);
}
```

Register: `Test.add_func ("/fan-math/collapsed", test_fan_pose_collapsed);` after `/fan-math/open`.

- [ ] **Step 2: Run it**

Run the dock build. `FanMath.pose` already implements collapse (Task 3), so this test is
expected to **pass** straight away; it pins the behaviour the animation relies on. If it
fails, fix `FanMath.pose` to match the test before going on.

- [ ] **Step 3: Add `StackSource.launched`**

In `StackSource.vala`, after `public signal void loaded ();`:

```vala
    /*
     * Emitted when an entry, or the folder itself, is opened from one of this
     * source's popovers, so the dock tile can bounce.
     */
    public signal void launched ();
```

- [ ] **Step 4: Collapse and ghost icon in `FanLayout`**

Add fields after `alphas`:

```vala
    // The row being launched, and its icon, which is drawn again on top as a
    // "ghost" that grows and fades (FanMath.ghost_scale).
    private int clicked = -1;
    private Gtk.Widget? clicked_icon = null;
    private Graphene.Point[] pivots = {};
```

Add methods after `clear ()`:

```vala
    public Gtk.Widget? row_at (uint i) {
        return i < rows.length ? rows[i] : null;
    }

    /* Starts a launch from row, whose icon widget is icon; collapse then drives it. */
    public void start_launch (Gtk.Widget row, Gtk.Widget icon) {
        uint index;
        clicked = rows.find (row, out index) ? (int) index : -1;
        clicked_icon = icon;
        // No second click while the fan folds away.
        can_target = false;
        queue_allocate ();
    }

    public void reset_launch () {
        clicked = -1;
        clicked_icon = null;
        can_target = true;
        collapse = 0;
    }
```

In `clear ()`, before `queue_resize ();`, add `clicked = -1; clicked_icon = null;`.

In `size_allocate`, add `pivots = new Graphene.Point[rows.length];` with the other arrays,
pass `i == clicked` as the third argument of `FanMath.pose`, and store the pivot:

```vala
            var pose = FanMath.pose (i, collapse, i == clicked);
            Graphene.Point pivot = { origin_x + (float) pose.x, origin_y + (float) pose.y };
            pivots[i] = pivot;

            // Pivot on the icon's centre, so the icons stay in one column.
            var transform = new Gsk.Transform ()
                .translate (pivot)
                .rotate ((float) pose.degrees)
                .translate ({ -(row_w - ICON_SIZE / 2.0f), -FanMath.ROW_HEIGHT / 2.0f });
```

At the end of `snapshot`, after the loop:

```vala
        if (clicked >= 0 && clicked_icon != null && collapse < 1) {
            // The icon sits centred on the row's pivot, so zoom about the pivot.
            var width = clicked_icon.get_width ();
            var height = clicked_icon.get_height ();
            var scale = (float) FanMath.ghost_scale (collapse);
            var transform = new Gsk.Transform ()
                .translate (pivots[clicked])
                .rotate ((float) tilts[clicked])
                .scale (scale, scale)
                .translate ({ -width / 2.0f, -height / 2.0f });
            snapshot.push_opacity (1 - collapse);
            StackRender.append_supersampled (snapshot, clicked_icon, transform, width, height);
            snapshot.pop ();
        }
```

- [ ] **Step 5: Animation in `FanPopover`**

Add a constant and a field:

```vala
    // How long a clicked row takes to zoom away while the rest fold into the tile.
    private const uint LAUNCH_MS = 250;

    private Adw.TimedAnimation launch_animation;
```

In `construct`, after `child = fan;`:

```vala
        // The target holds the fan, not this popover, so the animation forms no cycle.
        launch_animation = new Adw.TimedAnimation (fan, 0, 1, LAUNCH_MS, new Adw.PropertyAnimationTarget (fan, "collapse")) {
            easing = EASE_OUT_CUBIC
        };
        launch_animation.done.connect (popdown);
        closed.connect (on_closed);
```

Replace `open_location` with:

```vala
    private void open_location () {
        launch_row (header);
        source.open_location ();
    }
```

Add:

```vala
    /*
     * Zooms row's icon away and folds the rest of the fan into the tile, then
     * closes. The caller opens the file itself, right away: nothing waits on this.
     */
    private void launch_row (Gtk.Widget row) {
        if (launch_animation.state == PLAYING) {
            return;
        }
        fan.start_launch (row, row_icon (row));
        launch_animation.play ();
        source.launched ();
    }

    // Every row is a button around create_row_box (), whose last child is the icon.
    private static Gtk.Widget row_icon (Gtk.Widget row) {
        return ((Gtk.Button) row).child.get_last_child ();
    }

    private void on_closed () {
        launch_animation.reset ();
        fan.reset_launch ();
    }

    /*
     * Test hook for DOCK_STACKS_CLICK (see StackItem): plays row's launch
     * without opening anything, or, with progress in 0–1, holds the fan at that
     * point of it so a screenshot can catch it.
     */
    public void launch_for_test (uint row, double progress) {
        var widget = fan.row_at (row);
        if (widget == null) {
            warning ("DOCK_STACKS_CLICK: no row %u", row);
            return;
        }
        if (progress < 0) {
            launch_row (widget);
            return;
        }
        fan.start_launch (widget, row_icon (widget));
        fan.collapse = progress;
        source.launched ();
    }
```

In `create_row`, replace the `clicked` handler with:

```vala
        button.clicked.connect ((b) => {
            var popover = (FanPopover?) b.get_ancestor (typeof (FanPopover));
            if (popover != null) {
                popover.launch_row (b);
            }
            entry.launch ();
        });
```

Add a line to the class comment: `A click zooms the row's icon away and folds the rest
back into the tile (FanLayout.collapse) before the fan closes.`

- [ ] **Step 6: `DOCK_STACKS_CLICK` hook in `StackItem`**

Replace `open_for_test` with:

```vala
    private void open_for_test () {
        if (torn_down) {
            return;
        }
        popover_menu.popup ();
        if (Environment.get_variable ("DOCK_STACKS_CLICK") != null) {
            Timeout.add_once (700, click_for_test);
        }
    }

    // Test hook: DOCK_STACKS_CLICK=<row>[@<progress>], with DOCK_STACKS_OPEN, plays
    // that fan row's launch (row 0 is the newest entry, the last row "Open in
    // Files") and the tile's bounce, without opening anything. With a progress
    // (0–1) the fan holds at that point instead, for a screenshot.
    private void click_for_test () {
        if (torn_down || !(popover_menu is FanPopover)) {
            return;
        }
        var parts = Environment.get_variable ("DOCK_STACKS_CLICK").split ("@", 2);
        var progress = parts.length > 1 ? double.parse (parts[1]) : -1;
        ((FanPopover) popover_menu).launch_for_test ((uint) int.parse (parts[0]), progress);
    }
```

- [ ] **Step 7: Build and run the tests**

Run the dock build. Expected: success; `/fan-math/open` and `/fan-math/collapsed` pass.

- [ ] **Step 8: Look at it**

Frozen frames first, for a deterministic picture:

```bash
just pantheon::dock-run "$S/dock.log" DOCK_STACKS_OPEN=0 DOCK_STACKS_CLICK=2@0.4
# wait ~3 s
just pantheon::shot "$S/launch-40.png" 1000 300 1500 1140
just pantheon::dock-run "$S/dock.log" DOCK_STACKS_OPEN=0 DOCK_STACKS_CLICK=2@0.8
just pantheon::shot "$S/launch-80.png" 1000 300 1500 1140
```

Check: row 2's icon is larger (about 1.24× at 0.4, 1.48× at 0.8) and translucent, not
clipped at the popover edge; the other rows have slid down toward the tile, untilted and
faded; no row is drawn twice at full opacity. Then the real thing,
`DOCK_STACKS_CLICK=2` (no progress), and confirm in `dock.log` that the fan closed (no
`CRITICAL`, and a second `DOCK_STACKS_OPEN` cycle — change `stacks` as in Task 4 — reopens
it fully expanded, proving `reset_launch` ran). Restore the stock dock.

- [ ] **Step 9: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src/FanLayout.vala \
  modules/constellation/pantheon-dock/stacks/src/FanPopover.vala \
  modules/constellation/pantheon-dock/stacks/src/StackSource.vala \
  modules/constellation/pantheon-dock/stacks/src/StackItem.vala \
  modules/constellation/pantheon-dock/stacks/src/tests/StackTests.vala
git commit -m "feat(modules): animate a dock fan item as it opens"
```

---

### Task 6: Tile bounce on launch

**Files:**
- Modify: `modules/constellation/pantheon-dock/stacks/src/StackItem.vala`
- Modify: `modules/constellation/pantheon-dock/stacks/src/GridPopover.vala`

**Interfaces:**
- Consumes: `StackSource.launched` (Task 5); `BaseItem.overlay` (upstream, `protected Gtk.Overlay`).

- [ ] **Step 1: Grid emits `launched`**

`GridPopover.on_activate` becomes:

```vala
    private void on_activate (uint position) {
        var entry = (StackEntry) source.entries.get_item (position);
        popdown ();
        source.launched ();
        entry.launch ();
    }
```

- [ ] **Step 2: Bounce in `StackItem`**

Fields, after `torn_down`:

```vala
    // The launch bounce. Launcher.animate_launch plays the same one, but its
    // animations are private to Launcher, so this is a copy rather than a share.
    private Adw.TimedAnimation? bounce_up;
    private Adw.TimedAnimation? bounce_down;
```

In `construct`, after `gesture_click.released.connect (on_released);`:

```vala
        var bounce_target = new Adw.CallbackAnimationTarget (bounce_frame);
        bounce_down = new Adw.TimedAnimation (this, 0, 0, 600, bounce_target) {
            easing = EASE_OUT_BOUNCE
        };
        bounce_up = new Adw.TimedAnimation (this, 0, 0, 200, bounce_target) {
            easing = EASE_IN_OUT_QUAD
        };
        bounce_up.done.connect (on_bounce_up_done);
        source.launched.connect (animate_launch);
```

Methods, after `on_released`:

```vala
    private void bounce_frame (double value) {
        overlay.allocate (
            overlay.get_width (), overlay.get_height (), -1,
            new Gsk.Transform ().translate ({ 0, (int) value })
        );
    }

    // A method, not a connection to bounce_down.play: teardown () may drop
    // bounce_down while bounce_up is still playing.
    private void on_bounce_up_done () {
        if (bounce_down != null) {
            bounce_down.play ();
        }
    }

    private void animate_launch () {
        if (bounce_up == null || bounce_up.state == PLAYING || bounce_down.state == PLAYING) {
            return;
        }
        bounce_up.value_to = -0.5 * overlay.get_height ();
        bounce_down.value_from = bounce_up.value_to;
        bounce_up.play ();
    }
```

In `teardown`, after `pile.stop ();`:

```vala
        source.launched.disconnect (animate_launch);
        // The bounce target's callback holds this item; Launcher drops its
        // animations in cleanup () for the same reason.
        bounce_up = null;
        bounce_down = null;
```

- [ ] **Step 3: Build**

Run the dock build. Expected: success, tests pass.

- [ ] **Step 4: Look at it**

```bash
just pantheon::dock-run "$S/dock.log" G_MESSAGES_DEBUG=all DOCK_STACKS_OPEN=0 DOCK_STACKS_CLICK=2
```

The bounce takes 800 ms after the click at ~2.2 s; `shot` is too slow to time reliably, so
take three shots of the tiles in quick succession and check that at least one shows the
Downloads tile raised, and the last shows it back in place. Then force a teardown as in
Task 4 and confirm `StackItem finalized for …/Downloads` appears in the log: the bounce
target must not keep the item alive. Restore the stock dock.

- [ ] **Step 5: Commit**

```bash
git add modules/constellation/pantheon-dock/stacks/src/StackItem.vala \
  modules/constellation/pantheon-dock/stacks/src/GridPopover.vala
git commit -m "feat(modules): bounce a dock stack's tile when it opens something"
```

---

### Task 7: Schema text, docs, VM test, deploy

**Files:**
- Modify: `modules/constellation/pantheon-dock/stacks/hooks.patch` (schema description line)
- Modify: `modules/constellation/pantheon-dock/zoom/hooks.patch` (the same line, as context)
- Modify: `modules/constellation/pantheon-dock/CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-10-31-dock-stacks-polish-design.md`

- [ ] **Step 1: Schema description**

The stacks patch adds the line, and the zoom patch quotes it as context, so both change
together. **First check `git status --short modules/constellation/pantheon-dock/zoom/`.** If
`zoom/hooks.patch` has uncommitted changes, another session owns it: skip this step, leave
the description saying `'stack' or 'folder'`, and tell the user it still needs doing.
Otherwise:

```bash
cd /home/arosenfeld/Code/nixos/modules/constellation/pantheon-dock
sed -i "s/display is 'stack' or 'folder'\./display is 'stack', 'grid' or 'folder'./" stacks/hooks.patch zoom/hooks.patch
grep -c "'stack', 'grid' or 'folder'" stacks/hooks.patch zoom/hooks.patch
```

Expected: `1` for each file. Run the dock build; both patches must still apply.

- [ ] **Step 2: Docs**

`CLAUDE.md`, in the "Never inject input" bullet, after the sentence about `DOCK_STACKS_OPEN`:

```markdown
  `DOCK_STACKS_CLICK=<row>[@<progress>]`, set alongside it, plays that fan row's launch
  animation and the tile bounce 0.7 s after the fan opens, without opening anything; with
  a progress (0–1) the fan holds at that frame, which is the only way to screenshot it.
```

Spec: in section 2, replace "`FanPopover` emits `launched`." with "`FanPopover` emits
`StackSource.launched` (on the source, so `StackItem` can disconnect it in `teardown ()` like
its other source handlers)." and replace "the clicked row's icon scales from 1 to about
1.6 about its centre and fades to 0, and its label fades to 0;" with "the clicked row fades
to 0 while a ghost copy of its icon, drawn on top, scales from 1 to 1.6 about its centre
and fades with it;". If Task 3 took the fallback, add a line under section 3 saying so.

- [ ] **Step 3: VM test**

```bash
cd /home/arosenfeld/Code/nixos
nix build -L .#checks.x86_64-linux.pantheon-dock-test 2>&1 | tail -n 30
```

Expected: success (dock starts with both stacks, survives the invalid value, logs no crash).

- [ ] **Step 4: Commit**

```bash
git add modules/constellation/pantheon-dock/CLAUDE.md \
  docs/superpowers/specs/2026-10-31-dock-stacks-polish-design.md
# Only if Step 1 ran:
git add modules/constellation/pantheon-dock/stacks/hooks.patch modules/constellation/pantheon-dock/zoom/hooks.patch
git commit -m "docs(modules): document the dock stacks click hook and grid display"
```

- [ ] **Step 5: Push and deploy (ask the user first)**

Deploying raider restarts parts of the user's own session. Ask before running:

```bash
git push -u origin master
just deploy raider
```

Then the order from `pantheon-dock/CLAUDE.md`: the user logs out and back in, and only then
`dconf reset /io/elementary/dock/stacks` from a login shell if it was set by hand. Ask the
user to click a file in the Downloads fan and confirm the zoom, collapse and bounce.
