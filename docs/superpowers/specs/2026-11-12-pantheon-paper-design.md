# pantheon-paper: PaperWM-style scrolling tiling for Pantheon

## Goal

Scrolling tiling in the PaperWM model on raider and blackbird, while keeping Pantheon's
shell: Wingpanel, the patched dock, the global menu, the multitasking view and the
elementary apps. Only how windows are laid out changes. The flake's `niri` variant
already offers scrolling tiling, but it gives up that shell, which is the reason for
this work.

## Decisions

- **A Gala plugin, not a Gala patch.** Gala loads plugins (`Gala.Plugin`, a GModule) that
  receive the `Gala.WindowManager`, which is a `Meta.Plugin`: the full Mutter display,
  windows, workspaces, `window_group` for drawing, and `Meta.Display.add_keybinding` with
  a plugin-owned GSettings schema. That is everything the design needs. Patching Gala
  (the dock's approach) would buy a strip-aware multitasking view at the cost of
  rebasing on every Gala release, which the unattended weekly update would trip over.
  An external daemon is impossible: Gala exposes no Wayland protocol for moving other
  clients' windows.
- **Vala.** A Gala plugin is a GObject module built against `gala.vapi`; Rust is not a
  practical option here. Same toolchain as `pantheon-global-menu`.
- **Always on, every workspace.** No per-workspace or global mode switch; one behaviour
  to reason about. Individual windows can float.
- **Primary monitor only.** Pantheon keeps secondary monitors static (they do not follow
  workspace switches), so windows there stay floating.
- **First version scope:** strip with keyboard focus and scrolling, width presets and
  resize, columns (slurp/barf), mouse reorder and Super+scroll. Touchpad gestures are
  out of scope.

## Layout of the work

- Repo `arsfeld/pantheon-paper` (Vala, meson), the plugin.
- `packages/pantheon-paper/package.nix`: builds it pinned by commit, against `pkgs.pantheon.gala`
  and the Mutter in `gala.buildInputs` (the `findFirst` used by
  `packages/pantheon-global-menu/package.nix`). The derivation is written here rather
  than imported from the fetched tree, to avoid import-from-derivation.
- `modules/desktop/pantheon-paper.nix`: feature `flake.modules.nixos.pantheon-paper`,
  imported by `modules/desktop/desktop.nix` beside the other `pantheon-*` features. It
  installs the package through `environment.systemPackages` (Gala reads plugins from
  `/run/current-system/sw/lib/gala/plugins`), installs the plugin's GSettings schema,
  and writes the dconf overrides below. Option `constellation.desktop.paper.enable`,
  default `true` when the variant is `pantheon`. Gala reads plugins only at startup, so
  any change takes effect at the next login.

## Model

Per workspace, on the primary monitor:

```
Strip  { columns: List<Column>, scroll_x: int, focused: Window? }
Column { width: Preset(1/3 | 1/2 | 2/3) | Free(px), windows: List<Window>, heights: List<double> }
```

`heights` are shares of the column height (equal by default, changed by dragging an
edge between stacked windows).

A window joins a strip when it is `Meta.WindowType.NORMAL`, has no transient parent, is
not fullscreen, is on the primary monitor and has not been toggled to float. Dialogs,
popups, utility windows, Wingpanel and the dock never enter the model.

## Layout engine

`layout(strip, work_area) -> List<(window, rect, visible)>` is pure code with no Mutter
types, so the meson tests exercise it directly. Columns sit left to right with a fixed
gap, offset by `scroll_x`. A column that would show less than 75 px of itself inside the
work area is **parked**: pushed against the nearer screen edge so that a 75 px sliver
stays visible. A column that straddles the edge with more than that showing keeps its
natural position. Windows are moved as user operations (`move_resize_frame (true, …)`),
as PaperWM does: Mutter clamps any other move fully on screen, and keeps 75 px of a
user-op window visible, which is where the 75 comes from (10 px was the first plan and
is unreachable).

Scrolling follows focus. When the focused column is not fully visible, `scroll_x` moves
the minimum amount needed to show it. Super+C centres it instead.

The plugin's controller listens to Mutter signals (`window-created`, `unmanaging`,
`focus`, workspace changes, `size-changed`, grab begin and end, monitors changed). For
each one it updates the model, runs `layout`, then applies the result with
`move_resize_frame`. Pure moves (scrolling, reordering) animate through the window
actor's translation; resizes apply directly, because a Wayland resize lands only when
the client answers. Windows are dropped from the model on `unmanaging`: Mutter focuses
another window part-way through unmanaging one, and a relayout from that focus change
must not touch the dying window.

## Keys

All bindings go in the plugin's schema `io.github.arsfeld.paper.keybindings`, so they
can be changed in dconf.

| Key | Action |
|---|---|
| Super+←/→ | Focus the previous/next column |
| Super+↑/↓ | Focus the window above/below in the column |
| Super+Shift+←/→ | Move the column left/right |
| Super+Shift+↑/↓ | Move the window up/down within its column |
| Super+R | Cycle the column width 1/3 → 1/2 → 2/3 (from a Free width: snap to the nearest preset) |
| Super+M | Toggle the column at full work-area width (Super+F is Gala's picture-in-picture) |
| Super+I | Slurp: move the next column's top window into the focused column |
| Super+U | Barf: move the focused window out into its own column to the right (Super+O is rotation lock) |
| Super+C | Centre the focused column |
| Super+Shift+F | Toggle floating for the focused window (not Super+T, which Pantheon uses to open the Terminal) |

A new window opens as a new column (default width 1/2) to the right of the focused one
and takes focus.

Pantheon's defaults differ from GNOME's (elementary's gsettings overrides apply only
under `XDG_CURRENT_DESKTOP=Pantheon`), so collisions are judged against those, and
`just pantheon::paper-keys-check` fails on any clash in a built system. Against them, the
module changes, as system dconf defaults:

- `switch-to-workspace-left/right`: `<Super>Left/Right` → `<Control><Super>Left/Right`, so
  the strip has Super+←/→ (chosen on 2026-11-13 over moving the plugin's keys or giving
  workspaces no arrow key). Super+Home/End and Super+numbers still switch workspaces.
- `org.gnome.mutter.keybindings` `toggle-tiled-left/right` (Pantheon's Ctrl+Super+←/→
  half-screen tiling, which strips replace) cleared, and `edge-tiling` false.
- `move-to-monitor-{left,right,up,down}` (Super+Shift+arrows) cleared.
- The multitasking view keeps only `<Super>s`, dropping its `<Super>Down`.

Super+Up was already free in Pantheon. The Super-tap launcher is untouched. Elsewhere a
collision is resolved by moving the plugin's key, not by clearing Pantheon's (as with
Super+T, Super+F and Super+O).

## Mouse

- **Super+scroll** pans the strip (`scroll_x`) without changing focus: 200 px per wheel
  click, through a stage action in the capture phase as Gala's own Super+scroll uses.
  Clutter delivers each click twice (discrete and emulated smooth); the echo is
  swallowed.
- **Drag to pan (PaperWM).** A pointer move grab of a tiled window pans the whole strip
  with it (`DragPan` in `core/Drag.vala`), clamped as Super+scroll is, and on release
  the window returns to its slot. Pulling it more than 100 px (`DETACH_PX`) up or down,
  or onto another monitor, detaches it for the rest of the grab and the drop below
  applies. A keyboard move (Alt+F7) is detached from the start.
- **Drag to reorder.** During a detached move grab of a tiled window the plugin draws a drop
  indicator in `top_window_group` (above the windows). Dropping on the middle third of another column inserts
  the window into that column at the hovered position; dropping on the gap between two
  columns creates a new column there. Dropping elsewhere returns the window to its
  slot.
- **Resize.** Dragging the left or right edge of a tiled window sets the column to
  `Free(px)`. Dragging the top or bottom edge between stacked windows adjusts the
  `heights` shares. The strip re-lays out on grab end.
- Floating windows move and resize as in stock Gala.

## Edge cases

- **Apps that refuse a size** (minimum sizes, terminals snapping to whole cells): the
  strip lays out around the frame Mutter actually granted, read back after
  `size-changed`. A wider frame counts as a refusal only once the client has been asked
  for that exact width at least 1 s earlier; before that it is just the old size. A
  window asked for exactly its target size more than 1 s ago is left at whatever size it
  answered (not resizable, size increments, a minimum height) and only placed; a size
  the window takes by itself later voids that and it is asked once more. The layout is
  never retried in a loop.
- **Fullscreen:** the window leaves the strip while fullscreen and returns to its slot
  afterwards.
- **Minimize:** the window leaves the strip; on restore it comes back as a column next
  to the focused one.
- **Moved to another workspace:** it joins that workspace's strip as its last column.
- **A monitor beside the primary:** a column that would cross onto it is parked inside
  the edge instead, flush with it and lowered beneath the visible columns. Otherwise its
  majority would land on that monitor, and Mutter (with Pantheon's
  workspaces-only-on-primary) would make it sticky and take it out of the strip.
- **Moved to a secondary monitor:** dropped there at the end of a drag, it leaves the
  strip and floats. Monitor changes are otherwise ignored for tiled windows, because a
  parked window can sit mostly on the neighbouring monitor.
- **Fullscreen:** Gala moves a fullscreen window to a workspace of its own and back, so
  the saved slot remembers its workspace and the column's width, and is used only when
  the window re-enters that workspace.
- **Startup and first enable:** existing windows are adopted into their workspace's
  strip in stacking order, as columns at width 1/2.
- **Crash safety.** The plugin runs inside Gala, and a crash ends the Pantheon session
  (as with the global menu). Every signal handler checks that the window is still
  managed; the model drops a window in `unmanaging` before anything touches its actor;
  animations are cancelled when their window goes away.

## Testing

- **Unit tests** (meson, run in the package's `checkPhase`, so a failure fails raider's
  build): `layout` (gaps, parking at both edges, Free widths, height shares, scroll to
  focus, centring) and the strip operations (insert, remove, move, slurp, barf, width
  cycle).
- **On screen, on raider,** through the visual loop in
  `modules/desktop/pantheon-dock/CLAUDE.md`: `just pantheon::shot` to capture, never
  injected input. A test hook, `PAPER_DEMO=<n>` in Gala's environment, opens n test
  windows and runs a scripted sequence of strip actions with pauses, so each state can
  be captured.
- **Docs.** A CLAUDE.md section covering the plugin, its keys, the cleared bindings and
  the traps found during implementation.

## Out of scope

Touchpad gestures, strips on secondary monitors, a strip-aware multitasking view or
Alt-Tab (they show windows at their real, parked positions), per-app width rules, and
saving the layout across sessions.
