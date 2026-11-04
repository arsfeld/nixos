# Sharp Dock Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dock icons stay sharp when the zoom magnifies them and when stacks draw them tilted, while resting launchers look exactly as they do today.

**Architecture:** A third dock feature, `modules/desktop/pantheon-dock/icons/`, laid out like `stacks/` and `zoom/`. It holds a helper, `Dock.IconResolution`, that feeds a `Gtk.Image` a `Gtk.IconPaintable` looked up at `render_scale × oversample × scale-factor` while `pixel_size` stays the logical size, so the image lays out and takes CSS as before but carries a bigger bitmap. `BaseItem` gains `render_scale = ceil (zoom)`, which every dock-item image follows. Tilted stack icons use `oversample = 2`, and `StackRender.append_supersampled` multiplies its offscreen scale by the item's `render_scale`.

**Tech Stack:** Vala, GTK 4.22, libadwaita, meson; Nix overlay in `modules/desktop/pantheon-dock/default.nix`.

**Spec:** `docs/superpowers/specs/2026-11-03-dock-sharp-icons-design.md`

**Read first:** `modules/desktop/pantheon-dock/CLAUDE.md` (visual loop, Vala lifetime traps, GTK 4.22 icon breakage) and `modules/desktop/pantheon-dock/default.nix`.

## Global Constraints

- Upstream base: `elementary/dock` tag `8.3.3`. If `nix eval --raw .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock.version` no longer prints `8.3.3`, stop and rebase onto the new tag first.
- `pantheon-dock/default.nix` stays the only overlay of `elementary-dock`. Features apply in order: stacks, zoom, icons. `icons/hooks.patch` is generated on top of stacks and zoom.
- Local patch only. Never open an upstream PR or offer one.
- Commit straight to `master` in `~/Code/nixos`; no branches or worktrees there. The dock clone at `/home/arosenfeld/Code/elementary-dock` is a scratch repo and is never pushed.
- Commit messages in `~/Code/nixos`: conventional commits, scope `modules`. Never mention Claude.
- New files in `~/Code/nixos` are invisible to `nix build` until `git add`ed (`git add -N` is enough).
- Every icon remains a `Gtk.Image`; no replacement widget (CSS `-gtk-icon-shadow` on `.stack-icon` and symbolic recolouring must keep applying).
- `render_scale` is 1 at `zoom == 1.0`, so a resting dock must capture pixel-identical to the baseline from Task 1.
- Signal handlers on objects that outlive the call are methods, not lambdas capturing locals (`pantheon-dock/CLAUDE.md`).
- **A task that changes what the dock draws is not done until you have looked at it** with `just pantheon::dock-run` and `just pantheon::shot` and read the PNG. Never inject input: use `DOCK_ZOOM_AT` and `DOCK_STACKS_OPEN`.
- Never build or evaluate cylon-link. Evaluate one host at a time (raider only here).
- Run `just fmt` before committing Nix changes.

## Spec correction, made in Task 4

The spec sets `render_scale` to `ceil (max_factor)` while `zoom > 1`. This plan uses `ceil (zoom)` instead, which is `1` at rest, `2` for any zoom in `(1, 2]` and `3` above. It needs no access to `ZoomController`, it is always ≥ the zoom (so the bitmap is only ever scaled *down*), and with the default 84/48 = 1.75 it gives the same values. `IconMath.render_scale_for` therefore takes only the zoom. `DynamicWorkspaceIcon` (the "+" new-workspace item) is added to the consumers: it is zoomed like the others.

## File Structure

In the dock clone (`/home/arosenfeld/Code/elementary-dock`, branch `icons`, base tag `icons-base`):

| File | Responsibility |
|---|---|
| `src/Icons/IconMath.vala` (new) | Pure: `render_scale_for (zoom)`, `lookup_scale (surface, oversample, render_scale)`. No GTK. |
| `src/Icons/IconResolution.vala` (new) | The helper attached to one `Gtk.Image`. |
| `src/Icons/tests/IconMathTest.vala` (new) | GLib unit tests for `IconMath`. |
| `src/Icons/meson.build` (new) | `icons_sources`, and the `icon-math` test. |
| `src/meson.build` | `subdir('Icons')`, `sources += icons_sources`. |
| `src/BaseItem.vala` | `render_scale`, following `zoom`. |
| `src/AppSystem/Launcher.vala` | Launcher image through `IconResolution`. |
| `src/BaseIconGroup.vala` | Grid-tile minis through `IconResolution`. |
| `src/WorkspaceSystem/DynamicWorkspaceItem.vala` | "+" image through `IconResolution`. |
| `src/Stacks/StackRender.vala` | Public `OVERSAMPLE`, `render_scale` argument. |
| `src/Stacks/StackPile.vala` | Slots through `IconResolution`; `render_scale` property. |
| `src/Stacks/StackItem.vala` | Folder image through `IconResolution`; binds pile. |
| `src/Stacks/FanPopover.vala` | Row images through `IconResolution` at oversample 2. |

`src/Icons/` syncs to `pantheon-dock/icons/src/`, `src/Stacks/` to `pantheon-dock/stacks/src/`, and every other change becomes `pantheon-dock/icons/hooks.patch`.

In `~/Code/nixos`:

| File | Responsibility |
|---|---|
| `modules/desktop/pantheon-dock/icons/` (new) | `src/` and `hooks.patch`, by sync. |
| `modules/desktop/pantheon-dock/stacks/src/` | The four stacks files above, by sync. |
| `modules/desktop/pantheon-dock/default.nix` | `icons` appended to `features`; header comment. |
| `modules/desktop/pantheon-dock/CLAUDE.md` | "Icon resolution" section. |
| `docs/superpowers/specs/2026-11-03-dock-sharp-icons-design.md` | The correction above. |

## Development loop

Defined once here; tasks refer to it.

**Build shell** (from the clone root; every `meson`/`ninja` command runs inside it):

```bash
cd /home/arosenfeld/Code/elementary-dock
nix develop /home/arosenfeld/Code/nixos#nixosConfigurations.raider.pkgs.pantheon.elementary-dock
# first time in a fresh tree:
meson setup build
# every iteration:
ninja -C build && meson test -C build --print-errorlogs
```

**Sync** the clone into the nixos checkout (from the clone root):

```bash
P=/home/arosenfeld/Code/nixos/modules/desktop/pantheon-dock
mkdir -p "$P/icons"
rm -rf "$P/icons/src" && cp -r src/Icons "$P/icons/src"
rm -rf "$P/stacks/src" && cp -r src/Stacks "$P/stacks/src"
git diff icons-base -- . ':(exclude)src/Icons' ':(exclude)src/Stacks' > "$P/icons/hooks.patch"
git -C /home/arosenfeld/Code/nixos add -N modules/desktop/pantheon-dock/icons
```

`git diff icons-base` compares the working tree with the base, so uncommitted clone edits are included. After a sync, `git -C /home/arosenfeld/Code/nixos diff --stat -- modules/desktop/pantheon-dock/stacks` must list only the stacks files this task edited.

**Look at it** (from `~/Code/nixos`, after a sync). `D=/tmp/dock-icons`:

```bash
just pantheon::dock-run $D/dock.log DOCK_ZOOM_AT=9.5     # or another hook, see each task
sleep 4
just pantheon::shot $D/<name>.png <x> <y> <w> <h>
```

Capture areas (physical px, screen 3440×1440):

| Name | Hook | Area |
|---|---|---|
| `rest` | none | `1340 1360 760 70` |
| `zoom-stacks` | `DOCK_ZOOM_AT=9.5` | `1300 1250 840 190` |
| `zoom-launchers` | `DOCK_ZOOM_AT=3` | `1300 1250 840 190` |
| `fan` | `DOCK_STACKS_OPEN=0` | `1300 500 1100 940` |
| `grid` | `DOCK_STACKS_OPEN=1` | `1300 500 1100 940` |

If the dock is not where the table says (the launcher count changed), take a wide `0 1040 3440 400` shot first and narrow it. Enlarge crops 4× nearest-neighbour to judge sharpness:

```bash
nix shell nixpkgs#imagemagick -c magick $D/<name>.png -filter point -resize 400% $D/<name>-4x.png
```

Then Read the PNG. After each run, `grep -E "CRITICAL|WARNING" $D/dock.log` must print nothing new compared with the baseline log. When finished looking, give the session its own dock back:

```bash
pkill -f '(^|/)io\.elementary\.dock$'; sleep 3; pgrep -fa '(^|/)io\.elementary\.dock$'
```

Expected: one dock, from `/run/current-system`'s store path.

**Build through Nix** (runs the unit tests, since `doCheck = true`):

```bash
cd /home/arosenfeld/Code/nixos
nix build --no-link .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock
```

---

### Task 1: Base, baseline captures, and `IconMath` test-first, built through Nix

**Files:**
- Create (clone): `src/Icons/IconMath.vala`, `src/Icons/tests/IconMathTest.vala`, `src/Icons/meson.build`
- Modify (clone): `src/meson.build`
- Create (nixos): `modules/desktop/pantheon-dock/icons/src/`, `modules/desktop/pantheon-dock/icons/hooks.patch` (by sync)
- Modify (nixos): `modules/desktop/pantheon-dock/default.nix`

**Interfaces:**
- Produces, in namespace `Dock.IconMath`:
  - `int render_scale_for (double zoom)`: 1 for `zoom <= 1.0`, else `(int) Math.ceil (zoom)`.
  - `int lookup_scale (int surface_scale, int oversample, int render_scale)`: the product.
- Produces, in meson: `icons_core_sources`, `icons_sources`.
- Produces, in `default.nix`: `features` = stacks, zoom, icons (`dest = "Icons"`).

- [ ] **Step 1: Capture the baseline before changing anything**

From `~/Code/nixos`, with `D=/tmp/dock-icons` and `mkdir -p $D/before`, capture all five rows of the capture table into `$D/before/` (for `rest`, run `dock-run` with no hook so the build is the same as the others). Keep `$D/before/dock.log` from the `rest` run. Read each PNG and note in your report what you see: the zoomed icons and the fan's document icons are soft, the grid popover is sharp. Restore the session's dock.

- [ ] **Step 2: Rebuild the clone's base from the committed patches**

The clone's existing `zoom` branch has drifted from what `~/Code/nixos` carries, so build a fresh base:

```bash
cd /home/arosenfeld/Code/elementary-dock
git status --short          # must print nothing; stop and report if it does
P=/home/arosenfeld/Code/nixos/modules/desktop/pantheon-dock
git switch -c icons 8.3.3
git apply "$P/stacks/hooks.patch" && cp -r "$P/stacks/src" src/Stacks
git apply "$P/zoom/hooks.patch" && cp -r "$P/zoom/src" src/Zoom
git add -A && git commit -m "Base: 8.3.3 with stacks and zoom"
git tag icons-base
```

Expected: both `git apply` print nothing. `grep -c "^echo build/" .git/info/exclude || echo build/ >> .git/info/exclude` keeps the build dir out.

- [ ] **Step 3: Write the failing test and its meson file**

`src/Icons/tests/IconMathTest.vala`:

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 */

int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/icon-math/rest-is-native", () => {
        assert (Dock.IconMath.render_scale_for (1.0) == 1);
    });

    Test.add_func ("/icon-math/never-below-one", () => {
        assert (Dock.IconMath.render_scale_for (0.5) == 1);
    });

    Test.add_func ("/icon-math/zoom-rounds-up", () => {
        // Any magnification at all needs the next whole scale, so the bitmap is only ever shrunk.
        assert (Dock.IconMath.render_scale_for (1.001) == 2);
        assert (Dock.IconMath.render_scale_for (1.75) == 2);
        assert (Dock.IconMath.render_scale_for (2.0) == 2);
        // 104 / 48, the largest zoom-size that fits the headroom.
        assert (Dock.IconMath.render_scale_for (104.0 / 48.0) == 3);
    });

    Test.add_func ("/icon-math/lookup-scale", () => {
        assert (Dock.IconMath.lookup_scale (1, 1, 1) == 1);
        assert (Dock.IconMath.lookup_scale (1, 2, 1) == 2);
        assert (Dock.IconMath.lookup_scale (1, 2, 2) == 4);
        assert (Dock.IconMath.lookup_scale (2, 1, 2) == 4);
        assert (Dock.IconMath.lookup_scale (2, 2, 2) == 8);
    });

    return Test.run ();
}
```

`src/Icons/meson.build`:

```meson
# Copied into the dock's src/Icons/ by modules/desktop/pantheon-dock/default.nix.
# IconMath.vala must not touch GTK: the unit test links only it and runs
# inside the Nix build sandbox.
icons_core_sources = files(
    'IconMath.vala',
)

icons_sources = icons_core_sources

icons_test = executable(
    'icon-math-test',
    icons_core_sources + files('tests' / 'IconMathTest.vala'),
    dependencies: dependencies,
)

test('icon-math', icons_test)
```

In `src/meson.build`, after `subdir('Zoom')` add `subdir('Icons')`, and after `sources += zoom_sources` add `sources += icons_sources`.

- [ ] **Step 4: Run it to make sure it fails**

In the build shell: `meson setup build --wipe 2>/dev/null || meson setup build`, then `ninja -C build`.
Expected: meson fails because `IconMath.vala` does not exist.

- [ ] **Step 5: Write `IconMath`**

`src/Icons/IconMath.vala`:

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 */

/**
 * How big an icon's bitmap must be, kept free of GTK so it can be unit tested.
 */
namespace Dock.IconMath {
    /**
     * The whole-number scale an item zoomed by zoom must rasterize its icons at:
     * 1 at rest, so resting icons keep their native bitmaps, and otherwise the
     * next whole number at or above the zoom, so the bitmap is only ever shrunk.
     */
    public int render_scale_for (double zoom) {
        if (zoom <= 1.0) {
            return 1;
        }
        return (int) Math.ceil (zoom);
    }

    /** The scale to look an icon up at, for IconTheme.lookup_by_gicon. */
    public int lookup_scale (int surface_scale, int oversample, int render_scale) {
        return surface_scale * oversample * render_scale;
    }
}
```

- [ ] **Step 6: Run the tests and make sure they pass**

`ninja -C build && meson test -C build --print-errorlogs`
Expected: `icon-math`, `stacks` and `zoom-math` all `OK`.

- [ ] **Step 7: Wire the feature into Nix**

In `modules/desktop/pantheon-dock/default.nix`, append to `features`:

```nix
          {
            dir = ./icons;
            dest = "Icons";
          }
```

and add to the header comment, after the `zoom/` paragraph:

```nix
# icons/: keeps icons sharp when zoom magnifies them or stacks draw them tilted.
# IconResolution looks each icon up at the size it finally covers on screen;
# its hooks.patch routes the launcher, the grid-tile minis and the "+" item
# through it. Design: docs/superpowers/specs/2026-11-03-dock-sharp-icons-design.md
```

Sync (development loop), `just fmt`, then build through Nix.
Expected: the build succeeds and its log shows `icon-math` passing (`nix log` on the output if needed).

- [ ] **Step 8: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add modules/desktop/pantheon-dock/icons modules/desktop/pantheon-dock/default.nix
git commit -m "feat(modules): dock icons feature with the icon resolution math"
```

---

### Task 2: `IconResolution`, `BaseItem.render_scale`, and the upstream images

**Files:**
- Create (clone): `src/Icons/IconResolution.vala`
- Modify (clone): `src/Icons/meson.build`, `src/BaseItem.vala`, `src/AppSystem/Launcher.vala`, `src/BaseIconGroup.vala`, `src/WorkspaceSystem/DynamicWorkspaceItem.vala`
- Modify (nixos, by sync): `modules/desktop/pantheon-dock/icons/`

**Interfaces:**
- Consumes: `Dock.IconMath.render_scale_for`, `Dock.IconMath.lookup_scale` (Task 1).
- Produces:
  - `class Dock.IconResolution : Object` with `Icon? icon { get; set; }`, `int render_scale { get; set; default = 1; }`, and `static IconResolution attach (Gtk.Image image, Icon? icon, int oversample = 1)`. The image owns the returned helper.
  - `Dock.BaseItem.render_scale` (`int`, read-only outside `BaseItem`, notifies only when it changes).

- [ ] **Step 1: Write `IconResolution`**

`src/Icons/IconResolution.vala`:

```vala
/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Gives a Gtk.Image a bitmap sized for what it finally covers on screen.
 * Gtk.Image picks its bitmap from the widget's scale factor alone, so an icon
 * that a transform later magnifies (the zoom) or that is painted into a
 * supersampled texture (StackRender) is a stretched 1× bitmap. This looks the
 * icon up at render_scale × oversample × the scale factor and hands the image
 * the paintable, while pixel_size stays the logical size: layout and icon CSS
 * (-gtk-icon-shadow, symbolic recolouring) are unchanged.
 */
public class Dock.IconResolution : Object {
    private const string KEY = "dock-icon-resolution";

    public Icon? icon { get; set; }
    public int render_scale { get; set; default = 1; }

    // Unowned: the image owns this helper (set_data in attach), not the reverse.
    private unowned Gtk.Image image;
    private int oversample;

    private IconResolution (Gtk.Image image, int oversample) {
        this.image = image;
        this.oversample = oversample;

        // Methods, not lambdas: valac connects them with g_signal_connect_object,
        // so they go away with this helper and hold no reference to it.
        notify["icon"].connect (update);
        notify["render-scale"].connect (update);
        image.notify["pixel-size"].connect (update);
        image.notify["scale-factor"].connect (update);
        Gtk.IconTheme.get_for_display (image.get_display ()).changed.connect (update);
    }

    /* Takes over image's icon. Set icon on the returned helper, never gicon on the image. */
    public static IconResolution attach (Gtk.Image image, Icon? icon, int oversample = 1) {
        var resolution = new IconResolution (image, oversample);
        image.set_data<IconResolution> (KEY, resolution);
        resolution.icon = icon;
        return resolution;
    }

    private void update () {
        if (icon == null) {
            image.paintable = null;
            return;
        }
        // No logical size yet: let GTK size it, and look up again once pixel_size is set.
        if (image.pixel_size <= 0) {
            image.gicon = icon;
            return;
        }
        var scale = IconMath.lookup_scale (image.get_scale_factor (), oversample, render_scale);
        image.paintable = Gtk.IconTheme.get_for_display (image.get_display ())
            .lookup_by_gicon (icon, image.pixel_size, scale, image.get_direction (), 0);
    }
}
```

In `src/Icons/meson.build`, change `icons_sources = icons_core_sources` to:

```meson
icons_sources = icons_core_sources + files(
    'IconResolution.vala',
)
```

- [ ] **Step 2: Add `BaseItem.render_scale`**

In `src/BaseItem.vala`, after the `zoom` property that `zoom/hooks.patch` added:

```vala
    /** The scale icons inside this item rasterize at: IconMath.render_scale_for (zoom). */
    public int render_scale { get; private set; default = 1; }
```

In `construct`, next to `notify["zoom"].connect (lift_popovers);`:

```vala
        notify["zoom"].connect (update_render_scale);
```

and add the method next to `lift_popovers`:

```vala
    // Changes only when the zoom crosses a whole number, so images look their icon up
    // again a few times per hover, not every frame.
    private void update_render_scale () {
        var scale = IconMath.render_scale_for (zoom);
        if (scale != render_scale) {
            render_scale = scale;
        }
    }
```

- [ ] **Step 3: Route the launcher image through it**

In `src/AppSystem/Launcher.vala`, replace

```vala
        image = new Gtk.Image ();

        var icon = app.app_info.get_icon ();
        if (icon != null && Gtk.IconTheme.get_for_display (Gdk.Display.get_default ()).has_gicon (icon)) {
            image.gicon = icon;
        } else {
            image.gicon = new ThemedIcon ("application-default-icon");
        }
```

with

```vala
        image = new Gtk.Image ();

        var icon = app.app_info.get_icon ();
        if (icon == null || !Gtk.IconTheme.get_for_display (Gdk.Display.get_default ()).has_gicon (icon)) {
            icon = new ThemedIcon ("application-default-icon");
        }
        var resolution = IconResolution.attach (image, icon);
        bind_property ("render-scale", resolution, "render-scale", SYNC_CREATE);
```

- [ ] **Step 4: Route the grid-tile minis through it**

In `src/BaseIconGroup.vala`, `create_flow_box_child`, replace

```vala
        var image = new Gtk.Image.from_gicon ((Icon) item);
```

with

```vala
        var image = new Gtk.Image ();
        var resolution = IconResolution.attach (image, (Icon) item);
        bind_property ("render-scale", resolution, "render-scale", SYNC_CREATE);
```

- [ ] **Step 5: Route the "+" item through it**

In `src/WorkspaceSystem/DynamicWorkspaceItem.vala`: add a field `private IconResolution resolution;` under `private Gtk.Image image;`. Replace

```vala
        image = new Gtk.Image.from_icon_name ("list-add-symbolic") {
```

with

```vala
        image = new Gtk.Image () {
```

and directly after that initializer's closing `};` add

```vala
        resolution = IconResolution.attach (image, new ThemedIcon ("list-add-symbolic"));
        bind_property ("render-scale", resolution, "render-scale", SYNC_CREATE);
```

In `window_entered` replace `image.gicon = window.icon;` with `resolution.icon = window.icon;`, and in `window_left` replace `image.icon_name = "list-add-symbolic";` with `resolution.icon = new ThemedIcon ("list-add-symbolic");`.

- [ ] **Step 6: Build and test**

In the build shell: `ninja -C build && meson test -C build --print-errorlogs`.
Expected: no new valac warnings from the files touched; all three tests `OK`.

- [ ] **Step 7: Check the spec's assumption on screen first**

Sync, then capture `zoom-launchers` into `$D/after/` and enlarge it 4×. Check, against `$D/before/zoom-launchers-4x.png`:
- every launcher is drawn at its usual size (not at 96 px, not at 16 px): this proves `Gtk.Image` draws a paintable at `pixel_size`;
- the magnified launchers have crisp edges where the baseline is soft;
- the "+" item is still grey (symbolic recolouring survived);
- `grep -E "CRITICAL|WARNING" $D/dock.log` shows nothing the baseline log lacks.

If the icons are drawn at the wrong size or lose their recolouring, stop and report: the spec's fallback (a small widget that snapshots the paintable itself) needs a design decision.

- [ ] **Step 8: Check the resting dock is unchanged**

Capture `rest` into `$D/after/` and compare:

```bash
nix shell nixpkgs#imagemagick -c magick compare -metric AE $D/before/rest.png $D/after/rest.png $D/rest-diff.png
```

Expected: `0`. If not, Read `$D/rest-diff.png`: differences are allowed only outside the icons (a running-app indicator or the stacks, which change in Task 3, or the desktop behind the dock's margins). Any difference inside a launcher icon is a bug: find it before going on. Restore the session's dock.

- [ ] **Step 9: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add modules/desktop/pantheon-dock/icons
git commit -m "feat(modules): dock launchers stay sharp while zoomed"
```

---

### Task 3: Stacks — pile, folder image, fan rows and the supersampled pass

**Files:**
- Modify (clone): `src/Stacks/StackRender.vala`, `src/Stacks/StackPile.vala`, `src/Stacks/StackItem.vala`, `src/Stacks/FanPopover.vala`
- Modify (nixos, by sync): `modules/desktop/pantheon-dock/stacks/src/` (those four files only)

**Interfaces:**
- Consumes: `Dock.IconResolution.attach`, `.icon`, `.render_scale`; `Dock.BaseItem.render_scale` (Task 2).
- Produces:
  - `Dock.StackRender.OVERSAMPLE` (public `int` const, 2).
  - `Dock.StackRender.append_supersampled (Gtk.Snapshot snapshot, Gtk.Widget widget, Gsk.Transform transform, float width, float height, int render_scale = 1)`.
  - `Dock.StackPile.render_scale` (`int` property, default 1).

- [ ] **Step 1: `StackRender` takes the zoom into its oversample**

In `src/Stacks/StackRender.vala`, replace `private const double OVERSAMPLE = 2;` with:

```vala
    // Also the oversample IconResolution must look tilted icons up at, or the
    // texture below holds a 1× bitmap stretched to 2×.
    public const int OVERSAMPLE = 2;
```

Change the signature to

```vala
    public void append_supersampled (Gtk.Snapshot snapshot, Gtk.Widget widget, Gsk.Transform transform, float width, float height, int render_scale = 1) {
```

and its scale line to

```vala
        // render_scale: a zoomed item scales this texture up again afterwards.
        var scale = (float) (OVERSAMPLE * render_scale * native.get_surface ().get_scale ());
```

Update the header comment's "at twice the surface scale" to "at twice the surface scale (times the item's zoom render_scale)".

- [ ] **Step 2: `StackPile` slots through `IconResolution`**

In `src/Stacks/StackPile.vala`:

Add the property after `icon_size`:

```vala
    /** The owning item's BaseItem.render_scale. */
    public int render_scale { get; set; default = 1; }
```

Add a field after `images`:

```vala
    private GenericArray<IconResolution> resolutions = new GenericArray<IconResolution> ();
```

In `construct`, replace the image-creation loop with:

```vala
        for (int k = 0; k < SIZES.length; k++) {
            var image = new Gtk.Image ();
            image.set_parent (this);
            images.add (image);
            // Tilted slots are painted through StackRender's supersampled texture.
            resolutions.add (IconResolution.attach (image, null, DEGREES[k] == 0 ? 1 : StackRender.OVERSAMPLE));
        }
```

and after `notify["icon-size"].connect (update_sizes);` add `notify["render-scale"].connect (update_render_scale);`.

In `dispose`, add `resolutions.length = 0;` before `images.length = 0;`.

Add the method after `update_sizes`:

```vala
    private void update_render_scale () {
        foreach (var resolution in resolutions) {
            resolution.render_scale = render_scale;
        }
        queue_draw ();
    }
```

In `update_icons`, replace `images[k].gicon = ((StackEntry) source.previews.get_item (k)).icon;` with `resolutions[k].icon = ((StackEntry) source.previews.get_item (k)).icon;`.

In `snapshot`, replace `StackRender.append_supersampled (snapshot, image, transforms[k], size, size);` with `StackRender.append_supersampled (snapshot, image, transforms[k], size, size, render_scale);`.

- [ ] **Step 3: `StackItem` folder image and the pile follow the item**

In `src/Stacks/StackItem.vala`, replace

```vala
        folder_image = new Gtk.Image.from_gicon (source.folder_icon ());
        bind_property ("icon-size", folder_image, "pixel-size", SYNC_CREATE);

        pile = new StackPile (source);
        bind_property ("icon-size", pile, "icon-size", SYNC_CREATE);
```

with

```vala
        folder_image = new Gtk.Image ();
        var folder_resolution = IconResolution.attach (folder_image, source.folder_icon ());
        bind_property ("icon-size", folder_image, "pixel-size", SYNC_CREATE);
        bind_property ("render-scale", folder_resolution, "render-scale", SYNC_CREATE);

        pile = new StackPile (source);
        bind_property ("icon-size", pile, "icon-size", SYNC_CREATE);
        bind_property ("render-scale", pile, "render-scale", SYNC_CREATE);
```

- [ ] **Step 4: `FanPopover` rows at oversample 2**

In `src/Stacks/FanPopover.vala`, replace `new_row_image` with:

```vala
    // Fan rows are tilted, so they are painted through StackRender's supersampled
    // texture; the popover itself is never zoomed.
    private static Gtk.Image new_row_image (Icon? icon, int size) {
        var image = new Gtk.Image () { pixel_size = size };
        IconResolution.attach (image, icon, StackRender.OVERSAMPLE);
        image.add_css_class ("stack-icon");
        return image;
    }
```

Then `grep -n "gicon" src/Stacks/FanPopover.vala src/Stacks/StackProgressBar.vala src/Stacks/StackPile.vala src/Stacks/StackItem.vala` must print nothing: every icon on these images now goes through its helper.

- [ ] **Step 5: Build and test**

In the build shell: `ninja -C build && meson test -C build --print-errorlogs`.
Expected: all three tests `OK`, no new valac warnings.

- [ ] **Step 6: Look at it**

Sync, then capture `rest`, `zoom-stacks`, `fan` and `grid` into `$D/after/`, enlarge each 4×, and compare with `$D/before/`:
- `fan`: document icons and thumbnails have crisp edges; the `.stack-icon` shadow is still drawn under them; the header folder icon is still there.
- `rest`: the pile tile's tilted icons are crisper than the baseline; the launchers are unchanged (re-run the Task 2 `compare` and Read the diff: only the stack tiles may differ).
- `zoom-stacks`: the grid-tile minis and the pile are crisp under magnification.
- `grid`: unchanged — it was sharp and is not touched.
- `grep -E "CRITICAL|WARNING" $D/dock.log` shows nothing new, in each run.

Then check teardown, since `StackPile` gained an array of helpers: run `just pantheon::dock-run $D/dock.log G_MESSAGES_DEBUG=all`, change the stacks once through the patched schema (`GSETTINGS_SCHEMA_DIR=$(echo $(nix build --no-link --print-out-paths .#nixosConfigurations.raider.pkgs.pantheon.elementary-dock)/share/gsettings-schemas/*/glib-2.0/schemas) gsettings set io.elementary.dock stacks "[('~/Downloads', 'fan', 'date-added', 'stack')]"`), and confirm in the log that the removed `StackItem` logs its teardown/finalize debug lines and no `CRITICAL`. Reset with `dconf reset /io/elementary/dock/stacks` from a login shell (`fish -l -c '…'`), confirm `gsettings get` shows both stacks again, and restore the session's dock.

- [ ] **Step 7: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add modules/desktop/pantheon-dock/stacks/src modules/desktop/pantheon-dock/icons
git commit -m "feat(modules): dock stacks draw tilted and zoomed icons sharp"
```

---

### Task 4: Docs and the spec correction

**Files:**
- Modify (nixos): `modules/desktop/pantheon-dock/CLAUDE.md`, `docs/superpowers/specs/2026-11-03-dock-sharp-icons-design.md`

- [ ] **Step 1: Document the rule where the next change will read it**

In `modules/desktop/pantheon-dock/CLAUDE.md`, add before "## GTK 4.22 and elementary's icons":

```markdown
## Icon resolution

`Gtk.Image` rasterizes its icon for the widget's scale factor only. Anything that scales it
afterwards — the zoom's item transform, `StackRender`'s supersampled texture — stretches a
1× bitmap, which is what made zoomed and tilted icons blurry. So a dock image whose icon may
be drawn larger than its `pixel_size` gets its icon through `IconResolution.attach (image,
icon, oversample)` (`icons/src/`), never through `gicon`: set `icon` on the helper, bind
`render-scale` from its `BaseItem`, and pass `StackRender.OVERSAMPLE` if it is painted
tilted. `BaseItem.render_scale` is `ceil (zoom)` and 1 at rest, so resting icons keep their
native bitmaps. Popover images that are neither zoomed nor tilted (the Applications grid)
need none of this.
```

- [ ] **Step 2: Apply the spec correction**

In the spec, under "Where the extra resolution comes from", replace the **Zoom** bullet's first two sentences with: "`BaseItem` gains `render_scale` (int), `IconMath.render_scale_for (zoom)`: 1 at `zoom == 1`, else `ceil (zoom)` — 2 at the default 84/48, 3 above a zoom of 2. It is always at least the zoom, so a bitmap is only ever shrunk, and it needs nothing from `ZoomController`." In "Testing", replace `` `render_scale_for (zoom, max_factor)`, including `zoom == 1` → 1 and a `max_factor` above 2 → 3 `` with `` `render_scale_for (zoom)`, including `zoom == 1` → 1, 1.75 → 2 and 104/48 → 3 ``. Add a row to the consumers table: `` | `DynamicWorkspaceIcon` image (upstream, via hook): the "+" item | 1 | its item | ``, and mention `DynamicWorkspaceItem.vala` in the Packaging bullet's list of hooked files.

- [ ] **Step 3: Final build and commit**

```bash
cd /home/arosenfeld/Code/nixos
nix build --no-link .#nixosConfigurations.raider.config.system.build.toplevel
git add modules/desktop/pantheon-dock/CLAUDE.md docs/superpowers/specs/2026-11-03-dock-sharp-icons-design.md
git commit -m "docs(modules): dock icon resolution rule and spec correction"
```

Expected: raider's toplevel builds. Deploying is the user's call: report that `just deploy raider` (or `just test raider`) is the next step, and that the dock picks it up on its next restart without a re-login, since no gsettings key changed.
