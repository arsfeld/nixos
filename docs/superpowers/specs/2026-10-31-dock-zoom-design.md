# Dock zoom for the elementary dock

Status: design approved 2026-10-31. Hosts: raider, blackbird (both `constellation.desktop.variant = "pantheon"`).
Companion to `2026-10-31-dock-stacks-design.md`; both patch the same package through the same overlay.

## Goal

Recreate the macOS dock's magnification on Pantheon's dock: icons near the pointer grow on a
smooth falloff, their neighbours spread apart, and the dock widens while the pointer is over
it, then settles back when it leaves.

## Constraint: the dock has no zoom

`elementary-dock` 8.3.3 (`pantheon.elementary-dock`) has three settings: `autohide-mode`,
`icon-size` and `launchers`. Zoom is therefore a **local patch to the dock**, for the same
reasons the stacks spec gives. No upstream PR.

Two properties of 8.3.3 make the full macOS behaviour cheap enough:

- `MainWindow` keeps a 64 px transparent margin (`TOP_MARGIN`) above the icons for the launch
  bounce, and nothing clips to it (`overflow = VISIBLE`). Icons can grow upward into it
  without resizing the window vertically.
- The window already resizes every frame: `ItemGroup` animates its `width-request` when an
  app is added or removed, the window follows through a `Gtk.SizeGroup`, Gala keeps it
  centred, and the blur follows. Widening the dock during zoom reuses that path.

A fixed, oversized window with a self-drawn background was rejected: Gala's blur is set once
for the whole surface (`panel.add_blur`), so the blur would be wider than the visible dock.

## Configuration

The patch adds two keys to `data/dock.gschema.xml`:

```
io.elementary.dock zoom-enabled : b   default true
io.elementary.dock zoom-size    : i   default 84
```

`zoom-size` is the logical pixel size of the icon directly under the pointer. It is clamped to
`icon-size … icon-size + 64` (the headroom); a value outside that range logs one `warning ()`
and uses the clamped value. Both keys are watched for live changes.

### Nix side

In the Pantheon branch of `modules/constellation/desktop.nix`:

- The patch lives at `modules/constellation/desktop/elementary-dock-zoom.patch` and is appended
  to `patches` in the same `pantheon.overrideScope` overlay the stacks spec defines, **after**
  `elementary-dock-stacks.patch`. Whichever feature is implemented first creates the overlay;
  the second appends to it.
- Both patches touch `ItemManager.vala`. The zoom patch is generated against a tree that
  already has the stacks patch applied. If zoom lands first, the stacks patch is generated on
  top of it instead.
- A new option, `constellation.desktop.pantheon.dockZoom = {enable, size}`, with defaults
  `enable = true` and `size = 84`. It is written as system dconf defaults for
  `io/elementary/dock/zoom-enabled` and `zoom-size` in the Pantheon dconf profile, next to
  `dockStacks`. `gsettings set` still overrides it per user.

## Components

All zoom logic is in one new file. Existing files get narrow hooks only, to keep rebases small.

### `ZoomController` (new, `src/ZoomController.vala`)

A singleton that owns all zoom state.

- Inputs: the pointer x in `ItemManager` coordinates, or "pointer left"; the resting widths of
  all items in order.
- Output: a zoom factor per item, from 1.0 to `zoom-size / icon-size`, and a `changed` signal.
- Falloff: a cosine bell spanning 3 resting slots on each side of the pointer. Beyond that,
  factors are exactly 1.0.
- Pointer mapping: the window is centred, so when the dock widens by `extra`, its origin moves
  left by `extra / 2`. The controller maps the pointer back to resting coordinates with
  `rest_x = pointer_x − (zoomed_width − rest_width) / 2`, and computes every factor from
  `rest_x`. Factors never depend on the controller's own output, so the layout cannot feed back
  on itself and jitter. Near the dock's ends, icons drift slightly under the pointer, as they
  do on macOS.
- An `Adw` animation eases a global zoom amount between 0 and 1 on enter and leave. With
  animations disabled (`gtk-enable-animations`), the amount jumps straight to its target and
  zoom still follows the pointer.
- The falloff and the pointer mapping are pure static functions, so they can be unit tested.

### `BaseItem` (patched)

- New `zoom` property (double, default 1.0).
- Width becomes `launcher_size × zoom`.
- The icon bin is drawn with a `Gsk.Transform` scale anchored at its bottom centre, so it grows
  upward into the headroom. Badges, progress bars and the running indicator scale with it.

### `ItemGroup` (patched)

- `relayout ()` and `add_item ()` place items at the running sum of their zoomed widths instead
  of `launcher_size × i`.
- Width is `animated resting width + zoom extra`. The existing add and remove animation drives
  the first term and the zoom drives the second, so an app opening while the dock is zoomed
  still slides in.
- During hover, positions are set directly each frame. The 200 ms `animate_move` easing is kept
  for reorders and for adding and removing items.

Every item group zooms: app launchers, background apps, workspaces and, once implemented, the
stacks group. Stacks need no zoom-specific code.

### `ItemManager` (patched)

- Adds a `Gtk.EventControllerMotion` that feeds `ZoomController`.
- Applies factors from a frame-clock tick callback (`add_tick_callback`), so there is one
  relayout per frame, not one per motion event.
- The workspace separator scales its height with its neighbours.

### `MainWindow` (patched)

The input region starts at `TOP_MARGIN`, so today the headroom ignores the pointer. While the
zoom amount is above 0, the region's top is raised by `zoom-size − icon-size`, so the part of a
magnified icon above the dock bar is clickable and keeps the zoom alive. At rest it returns to
the current region. GTK picking follows the scale transform, so a click goes to the item drawn
under it.

### `Launcher.update_tooltip` (patched)

It currently derives the launcher's index, and so its `<Super>N` shortcut, from
`current_pos / launcher_size`, which is wrong while zoomed. It uses
`ItemGroup.get_index_for_item ()` instead.

## Zoom states

| Situation | Zoom |
|---|---|
| Pointer over the dock | follows the pointer |
| Pointer leaves, including autohide sliding the dock away | eases back to rest |
| An item's popover is open (stack fan or grid, right-click menu, background apps) | frozen at its current value, so the popover's anchor does not slide; when the popover closes it eases to rest unless the pointer is back over the dock |
| Drag-and-drop reorder, or a file dragged in | rest for the whole drag; reordering keeps its fixed slot sizes and its code is unchanged |
| `zoom-enabled = false` | the controller is idle and the layout is identical to unpatched 8.3.3 |

Tooltips do not freeze the zoom, because they already follow their item.

## Out of scope

- The X11 session path (`update_panel_x11`). raider and blackbird run Wayland.
- Docks on the side or top. elementary's dock anchors only to the bottom.
- Interaction between zoom and the launch bounce, beyond the icon still bouncing.

## Testing

1. **Unit:** a GLib test added to the dock's meson and run through `doCheck`. It checks that
   the falloff peaks at the pointer, is symmetric, is exactly 1.0 beyond 3 slots, and that
   `rest_x` round-trips through the pointer mapping.
2. **Build:** `nix build .#nixosConfigurations.raider.config.system.build.toplevel`. Both
   patches apply and the dock compiles.
3. **VM check:** extend the Pantheon VM check from the stacks spec (`flake-modules/checks.nix`).
   With `dockZoom` enabled, assert that `io.elementary.dock` is running and its journal has no
   zoom warnings. With `size = 500`, assert that the clamp warning is logged and the dock is
   still running.
4. **Manual on raider** after `just deploy raider`:
   - record a GIF of the pointer sweeping across the dock;
   - click the top of a magnified icon;
   - open a stack fan while zoomed;
   - drag a launcher to reorder it;
   - toggle `zoom-enabled` live with `gsettings`.

## Maintenance

The patch must be rebased whenever nixpkgs bumps `elementary-dock`. The weekly update routine
sees that as a build failure in `just dry-run @tier1` and fixes or reverts it, as it does for
the stacks patch. Unlike the stacks patch, this one cannot be purely additive, because zoom
changes how `ItemGroup` positions items. That is why all logic is in `ZoomController.vala`
and the edits to existing files are limited to the hooks listed above.
