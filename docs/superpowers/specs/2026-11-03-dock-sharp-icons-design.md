# Sharp dock icons under zoom and tilt

## Problem

Icons on the elementary dock blur in three places:

1. **Zoom.** `ItemGroup.get_item_transform` (`zoom/hooks.patch`) scales each item with a
   `Gsk.Transform`, up to 84/48 = 1.75×. Each `Gtk.Image` still rasterizes its icon at its
   resting `pixel_size`, so a zoomed item is a 48 px bitmap stretched. Stack tiles suffer
   most: the 2×2 grid tile's 16 px minis become 28 px.
2. **Stack pile tile, at rest.** The tilted slots of `StackPile` are drawn through
   `StackRender.append_supersampled`, which renders the widget into an offscreen texture at
   2× the surface scale and filters it back down. But `Gtk.Image` picks its bitmap from the
   *widget's* scale factor, not the snapshot's, so the icon is rasterized at 1× (36–41 px)
   and the 2× pass only upscales it before rotating. The supersample adds no detail.
3. **Fan popover rows**, which are tilted and go through the same path.

The Applications grid popover is sharp: its icons are upright and drawn at their real size.
That is the reference for "sharp".

Root cause in all three: the bitmap is chosen for the logical size, and a transform scales
it afterwards. The fix is to rasterize the icon at the size it finally covers on screen.

## Rejected alternatives

- **Always rasterize at zoom size and scale down.** Simpler, but every resting launcher
  becomes softer than today: elementary's icons are hinted for 48 px, and a downscaled
  84 px bitmap is not. It would not fix the tilted slots either.
- **Re-layout at the true size instead of a transform** (`pixel_size` following the zoom
  factor). Re-rasterizes every SVG on every animation frame and rewrites the zoom layout.

## Design

### `IconResolution`: a helper, not a widget

Every icon stays a `Gtk.Image`, so the dock's CSS keeps applying: the `-gtk-icon-shadow`
on `.stack-icon`, symbolic recoloring, icon filters. A replacement widget would lose them.

`IconResolution` is attached to one `Gtk.Image` and owns its icon. Instead of setting
`gicon`, it sets `paintable` to a private `SharpPaintable` that delegates to
`Gtk.IconTheme.lookup_by_gicon (icon, pixel_size, lookup_scale, direction, 0)`, while
`pixel_size` stays the logical size. The image lays out exactly as before, and its bitmap
carries `render_scale` times the pixels. `FileIcon` thumbnails take the same path.
`SharpPaintable` implements `Gdk.Paintable` and `Gtk.SymbolicPaintable` and forwards its
drawing and size calls to the `Gtk.IconPaintable`; `get_flags` returns
`STATIC_SIZE | STATIC_CONTENTS` itself, the same constants GTK's icon paintable returns; it exists because `Gtk.Image` resets the scale of a bare
`Gtk.IconPaintable` (see below).

It holds `icon` and `render_scale` (int, ≥ 1) as properties, and re-runs the lookup when
either changes, or when the image's `pixel-size` or `scale-factor` changes, or when the
icon theme emits `changed`. Its handlers are methods, not lambdas that capture locals
(`CLAUDE.md`: Vala pitfalls), and the handlers on the image go with the image, while the icon-theme handler goes when the helper is finalized, with the image's finalize.

The lookup scale is
`IconMath.lookup_scale (surface_scale, oversample, render_scale) = surface_scale × oversample × render_scale` (an integer product).
`IconMath` is pure and unit-tested, like `ZoomMath`.

**Assumption checked first, and what was found:** the design assumed `Gtk.Image` draws a
paintable at `pixel_size` (not at the paintable's intrinsic size) and applies
`-gtk-icon-shadow` to it. That held. A third behavior was not assumed and did not hold:
`gtk_icon_helper_load_paintable ()` (`gtk/gtkiconhelper.c`, GTK 4.22, around lines 129-132)
resets the `scale` of a bare `Gtk.IconPaintable` to the widget's scale factor, so setting
the `lookup_by_gicon` result directly gave back the 1× bitmap. Wrapping it in
`SharpPaintable`, which is not an icon paintable and so is not rescaled, is the fix. It
keeps `Gtk.Image`, so the fallback of a hand-written widget with a CSS `box-shadow` was not
needed.

### Where the extra resolution comes from

- **Zoom.** `BaseItem` gains `render_scale` (int), `IconMath.render_scale_for (zoom)`: 1 at
  `zoom == 1`, else `ceil (zoom)` — 2 at the default 84/48, 3 above a zoom of 2. It is always
  at least the zoom, so a bitmap is only ever shrunk, and it needs nothing from
  `ZoomController`. Resting items keep their native bitmaps, so the resting dock is unchanged.
- **Tilted slots.** `StackPile`'s tilted slots and `FanPopover`'s rows use
  `oversample = StackRender.OVERSAMPLE` (2). `StackRender.append_supersampled` takes a
  `render_scale` argument and renders its offscreen texture at
  `OVERSAMPLE × render_scale × surface_scale`, because a 2× texture that zoom then
  stretches to 1.75× would blur again. The pile passes its item's `render_scale`; the fan,
  which zoom never scales, passes 1.

### Consumers

| Image | oversample | render_scale from |
|---|---|---|
| `Launcher.image` (upstream, via hook) | 1 | its item |
| `StackItem.folder_image` | 1 | its item |
| `StackPile` upright slot | 1 | its item (through `StackPile.render_scale`) |
| `StackPile` tilted slots | 2 | its item |
| `BaseIconGroup` minis (upstream, via hook): the dock's 2×2 grid tile, and the workspace icon groups | 1 | its item |
| `DynamicWorkspaceIcon` image (upstream, via hook): the "+" item | 1 | its item |
| `FanPopover` row icons | 2 | 1 |

`GridPopover` cells are already sharp and are not changed.

### Packaging

A new feature directory, `modules/desktop/pantheon-dock/icons/`:

- `src/IconResolution.vala`, `src/IconMath.vala`, `src/tests/IconMathTest.vala`,
  `src/meson.build`;
- `hooks.patch`, generated on top of `zoom`'s: adds `BaseItem.render_scale`, sets it from
  `zoom`, and hands `Launcher`'s image, `BaseIconGroup.create_flow_box_child`'s images
  and `DynamicWorkspaceItem.vala`'s "+" image to `IconResolution`.

It is appended to `features` in `default.nix` after `zoom`, with `dest = "Icons"`. The
stacks sources are ours and are edited in place.

## Testing

- **Unit:** `IconMathTest` covers `lookup_scale` (surface 1 and 2, oversample 1 and 2,
  render_scale 1 and 2) and `render_scale_for (zoom)`, including
  `zoom == 1` → 1, 1.75 → 2 and 104/48 → 3.
- **Visual loop** (`CLAUDE.md`: `just pantheon::dock-run`, `just pantheon::shot`), with
  crops enlarged 4× nearest-neighbour, before and after:
  - the resting dock;
  - `DOCK_ZOOM_AT=9.5` (zoomed over the stacks);
  - `DOCK_ZOOM_AT=3` (zoomed over launchers);
  - `DOCK_STACKS_OPEN=0` (Downloads fan);
  - `DOCK_STACKS_OPEN=1` (Applications grid).
- **Success:** zoomed and tilted icons show edges as crisp as the grid popover's, the
  `.stack-icon` shadow is still drawn, and the resting launchers are pixel-identical to
  today's capture.
