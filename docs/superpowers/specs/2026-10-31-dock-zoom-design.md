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

`zoom-size` is the logical pixel size of the icon directly under the pointer. The icon's 6 px
top padding scales with it, so it is clamped to `icon-size … icon-size + floor(64 × icon-size /
(icon-size + 6))`, which is 48…104 at the default 48 px icons. A value outside that range logs
one `warning ()` and uses the clamped value. Both keys are watched for live changes.

### Nix side

In `modules/constellation/pantheon-dock/`, the one overlay of `pantheon.elementary-dock`
(see its `CLAUDE.md`):

- The zoom code lives in `zoom/`, laid out like `stacks/`: the new Vala files in `zoom/src/`
  are copied to the dock's `src/Zoom/`, and `zoom/hooks.patch` holds the edits to upstream
  files. `default.nix` applies the features in order, stacks then zoom, and `zoom/hooks.patch`
  is generated on top of the stacks one. (The first draft put it in
  `modules/constellation/desktop/`, which cannot exist: haumea fails with `directory 'desktop'
  conflicts with file 'desktop.nix'`.)
- A new option, `constellation.desktop.pantheon.dockZoom = {enable, size}`, with defaults
  `enable = true` and `size = 84`, sits next to `dockStacks`. It is written as system dconf
  defaults for `io/elementary/dock/zoom-enabled` and `zoom-size`. `gsettings set` still
  overrides it per user.

## Components

All zoom logic is in two new files, `src/Zoom/ZoomMath.vala` (pure arithmetic) and `src/Zoom/ZoomController.vala`. Existing files get narrow hooks only, to keep rebases small.

### `ZoomController` (new, `src/Zoom/ZoomController.vala`)

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
- Its position animation calls `ItemGroup.place_item ()` instead of `Gtk.Fixed.move ()`.
- New `get_open_popover ()`: the visible popover parented to the item, excluding its tooltip.
- New `get_icon_bottom ()`: the bottom of the icon itself, above the running-indicator strip.
  Items scale about it, so they grow upward only.
- New `index_changed ()` virtual, which `ItemGroup` calls whenever its items change.
  `Launcher` overrides it to refresh its tooltip.

### `ItemGroup` (patched)

- `ItemGroup` is no longer a `Gtk.Fixed`: it is a plain `Gtk.Widget` with its own `measure` and
  `size_allocate`. It places each item by a transform: translated to its resting position plus
  the extra width of every magnified item before it, and scaled about `get_icon_bottom ()`, so
  it grows up into the headroom. Badges, progress bars and the running indicator scale with it
  because they are inside the item. (A `Gtk.Fixed` was tried first. `GtkFixedLayout` measured
  its children through their transforms, so a zoomed item made the whole dock taller.) The
  vertical size stays the resting height.
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
- The dynamic "new workspace" item is wrapped in a one-item `ItemGroup`, so it zooms like the
  rest. The workspace separator does not scale.
- Test hook: `DOCK_ZOOM_AT=<slots>` zooms the dock 1 s after start as if the pointer rested
  that many launcher widths from its left edge, for screenshots without input injection.

### `MainWindow` (patched)

The input region starts at `TOP_MARGIN`, so today the headroom ignores the pointer. While the
zoom amount is above 0, the region's top is raised by how far the largest icon rises (`ZoomMath.rise`), so the part of a
magnified icon above the dock bar is clickable and keeps the zoom alive. At rest it returns to
the current region. GTK picking follows the scale transform, so a click goes to the item drawn
under it.

### `Launcher.update_tooltip` (patched)

It currently derives the launcher's index, and so its `<Super>N` shortcut, from
`current_pos / launcher_size`, which is wrong while zoomed. It uses `get_index ()` instead, and
`Launcher` refreshes its tooltip from `BaseItem.index_changed ()` whenever the group's items
change.

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
3. **VM check:** `tests/pantheon-dock-test.nix` (the stacks VM test, renamed), registered in
   `flake-modules/checks.nix`. `DOCK_ZOOM_AT` pins the zoom; it asserts that the hook fired,
   that the defaults log no zoom warnings, and that `zoom-size = 500` logs the clamp to 104
   with the dock still running. Screenshots of both are kept.
4. **Visual, on raider's live session** while developing: `just pantheon::dock-run` with
   `DOCK_ZOOM_AT` (and `DOCK_STACKS_OPEN` for popovers), then `just pantheon::shot`, per
   `modules/constellation/pantheon-dock/CLAUDE.md`.
5. **Manual on raider** after `just deploy raider`, for what needs a real pointer:
   - sweep the pointer across the dock;
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
