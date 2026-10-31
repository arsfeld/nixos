# Dock stacks polish: pile tile, click feedback, smooth fan

Follow-up to `2026-10-31-dock-stacks-design.md`. Three rough edges in the stacks under
`modules/constellation/pantheon-dock/stacks/`:

1. The Downloads tile shows the 2×2 preview grid that app groups use. macOS's
   "Display as Stack" shows a pile of the newest file icons instead.
2. Clicking a fan row makes the fan vanish with no sign that anything happened.
3. The tilted fan rows have jagged pill edges and text (see the 2026-10-31 11:19
   screenshot). Untilted rows near the dock are clean, so the cause is the rotation
   transform in `FanLayout`.

## 1. Tile display: `stack` becomes a pile, `grid` keeps the old preview

`display` grows from `stack | folder` to `stack | grid | folder`:

| Value    | Tile                                                                 |
|----------|----------------------------------------------------------------------|
| `stack`  | **New.** A pile of the newest entries' icons (`StackPile`)           |
| `grid`   | The `BaseIconGroup` 2×2 preview, unchanged (what `stack` drew before) |
| `folder` | Static folder icon, unchanged                                        |

- `StackConfig.Display` gains `GRID`; `StackConfig.parse` accepts `"grid"`; the Nix
  option enum in `pantheon-dock/default.nix` gains `"grid"`. The default stays `"stack"`.
- raider and blackbird set Applications to `display = "grid"`, so it looks the same as
  today. Downloads keeps the default and becomes the pile.
- **`StackPile`** (new `stacks/src/StackPile.vala`) is a `Gtk.Widget` sized to the
  item's `icon-size`. It draws up to three entries from `source.entries`:
  - entry 0 in front, upright, at about 90% of `icon-size`;
  - entries 1 and 2 behind it, a little smaller, offset up and sideways and tilted a
    few degrees in opposite directions.
  It uses the same `Icon` each entry already carries, so images show their thumbnails.
  It redraws on `entries.items_changed`. The exact offsets, sizes and angles are tuned
  in the visual loop, not fixed here.
- `StackItem.update_child` chooses between pile, grid preview and folder icon. An empty
  or missing source still shows the folder icon, as now. The grid preview stays
  `BaseIconGroup`'s own child, so its teardown (`bind_model (null, null)`) is unchanged.
  `StackPile` follows the existing rules: signal handlers are methods, and they are
  disconnected in `teardown ()`.

Upstream mismatch to keep in mind: `StackItem` remains a `BaseIconGroup` even when it
shows a pile, because that class is what `ItemManager`'s stack group expects. The 2×2
FlowBox is still built and simply isn't shown.

## 2. Click feedback: zoom, collapse, bounce

On a fan row click:

1. `entry.launch ()` runs **immediately**, so the file opens in parallel. Opening never
   waits on the animation.
2. `FanPopover` plays one `Adw.TimedAnimation` of 250 ms (ease-out) and blocks further
   clicks while it runs:
   - the clicked row's icon scales from 1 to about 1.6 about its centre and fades to 0,
     and its label fades to 0;
   - `FanLayout` gains a `collapse` property (0–1). It interpolates every other row's
     transform toward the origin (the bottom of the centre column, over the tile) and
     its opacity toward 0, so the fan runs back down into the tile.
   - On `done`: `popdown ()`, then `collapse` is reset to 0 and the clicked row restored,
     so the next open starts clean (the existing `dirty` rebuild still applies).
3. `FanPopover` emits `launched`. `StackItem` connects to it with a method and plays a
   single bounce: up for 200 ms (ease-in-out-quad) to half the overlay height, then down
   for 600 ms (ease-out-bounce), by allocating `overlay` with a translate, as
   `Launcher.animate_launch` does. That code is private to `Launcher`, so `StackItem`
   carries its own copy of these few lines rather than patching upstream to share them.
   The bounce plays once; unlike Launcher's, it does not repeat while the app is
   "launching".

"Open in Files" / "N more in Files" gets the same treatment. A click in the
`GridPopover` closes it immediately, as now, and emits the same `launched`, so the tile
bounces; the grid has no zoom.

If `gtk-enable-animations` is off, `Adw.TimedAnimation` jumps straight to its end, so the
fan closes at once, as today.

## 3. Smooth tilted rows: supersampled textures

Tilted rows are drawn through a texture instead of straight through the renderer:

- A small shared helper (`StackRender` in `stacks/src/`) takes a widget and a
  `Gsk.Transform`. It renders the widget's own snapshot upright into a texture at twice
  the surface scale (`Gsk.Renderer.render_texture` on the widget's native renderer),
  then appends it with `append_scaled_texture (..., LINEAR)` under the transform.
- `FanLayout.snapshot ()` uses it for every row with a non-zero tilt; untilted rows keep
  the normal `snapshot_child`. Allocation keeps the existing transform, so hit-testing,
  hover and drag sources are unchanged; only how a row is painted differs.
- `StackPile` uses the same helper for its tilted back icons, which would otherwise show
  the same jagged edges.
- Textures are rendered per frame only while a fan is mapped (about 12 rows) and on pile
  redraws. No caching unless the visual loop shows a real cost.

Before building this, try the dock under each other `GSK_RENDERER` for a few minutes, to
confirm the rotation path is the cause. That is a diagnosis step only, not the fix.

**Fallback:** if supersampled rows look soft or wrong on screen, set `MAX_DEGREES = 0`
in `FanLayout` and draw the pile's back icons untilted (offsets only), and delete
`StackRender`.

## Testing

- **Unit tests** (`stacks/src/tests/StackTests.vala`): `"grid"` parses to `GRID`; the
  collapse interpolation puts every row at its open position at 0 and at the origin at 1.
- **Test hook `DOCK_STACKS_CLICK=<row>`**: after `DOCK_STACKS_OPEN` opens the fan, plays
  that row's click animation and the tile bounce **without** launching anything, so
  `just pantheon::shot` can capture it mid-animation. This follows the "never inject
  input" rule in `pantheon-dock/CLAUDE.md`.
- **Visual loop on raider** (`just pantheon::dock-run` + `just pantheon::shot`): the pile
  on the Downloads tile, Applications unchanged, clean labels on the top rows of the fan,
  and the click animation captured mid-flight.
- **VM test** (`tests/pantheon-dock-stacks-test.nix`): give its Applications stack
  `display = "grid"` to mirror the hosts. It must still pass (no crash, no critical),
  and it then exercises both the pile and the grid preview.
- **Deploy**: `display` is a new value in an existing key, not a new key, so no schema
  guard is needed. As usual: deploy, re-login, then `dconf reset /io/elementary/dock/stacks`
  if it was set by hand.

## Out of scope

- A pile or zoom for the Applications grid.
- Repeating bounces tied to app startup notification.
- Per-stack choice of fan tilt.
