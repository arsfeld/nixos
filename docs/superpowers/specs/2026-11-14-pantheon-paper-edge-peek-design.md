# pantheon-paper: edge margin and edge previews

Status: design, approved in conversation 2026-11-14. Plugin repo: `arsfeld/pantheon-paper`
(checkout `~/Code/pantheon-paper`); pinned here as `packages/pantheon-paper`.

## Problem

When the focused column sits flush against the left or right edge of the screen there is
no sign of whether more columns lie beyond it.

Cause: `scroll_to_focus` (`src/core/Layout.vala`) scrolls the least needed, which leaves
a column that reaches an edge exactly flush with it. The neighbour beyond is parked as a
75 px sliver (`SLIVER`) inside that same edge, and `Applier` lowers parked windows beneath
the visible ones, so the sliver is hidden under the focused window. A column parked
against an edge that borders another monitor is parked flush and lowered, so it is hidden
completely.

## How PaperWM does it (read from source, `paperwm/PaperWM` at `2d460db`)

PaperWM draws no indicator. Its cues are:

1. **A horizontal margin** (`horizontal-margin`, default 20 px). `ensuredX`
   (`tiling.js`) never lines a focused window up closer than the margin to an edge, and
   off-screen windows sit at the same 75 px `stack_margin` beneath it, so about 20 px of
   the real neighbour window always shows at the edge.
2. **Full width keeps the margin.** Maximize-width is `workArea − 2 × margin − gap`, and
   a window wider than 90% of the usable area is centred, so both sides show a sliver.
3. **Edge previews** (`stackoverlay.js`). A thin reactive strip at each monitor edge;
   hovering it shows a 15%-scale live clone of the hidden window, a click activates it.

pantheon-paper copied the 75 px sliver but not the margin. This design adds both the
margin and the hover preview.

## Design

### 1. The margin (layout core)

- `Params.margin`, default 20 logical px, read live from the `margin` setting.
  **With `margin = 0` every formula below reduces to today's layout exactly**, so the
  existing layout tests stay valid unchanged and pin the old behaviour.
- Usable width `U = work.width − 2 × margin`.
  - A preset fraction `f` gives `round (U × f) − gap`: today's formula
    (`Params.pixels`), applied to `U` instead of `work.width`. Two ½ columns therefore
    span `U − gap`, the same one-gap slack the layout has today.
  - Full width (Super+M) is `U`.
  - A window's minimum width still overrides both, as now.
- Scrolling measures from the lines `work.x + margin` and `work.x + work.width − margin`
  instead of the screen edges:
  - `scroll_to_focus` scrolls the least needed to put the focused column inside those
    lines.
  - A column wider than `U` is **centred** in the work area (PaperWM's rule), replacing
    today's left-align.
  - `center_focus` is unchanged (it already centres on the work area).
  - A strip's first column starts `margin` in from the left: strip coordinate 0 maps to
    `work.x + margin` at `scroll_x = 0`.
  - `pan`'s half-screen clamp is unchanged.
- Parking is unchanged: the 75 px sliver, or flush inside an edge that borders another
  monitor, lowered beneath the visible columns. Because the focused column now ends
  `margin` short of the edge, the outer `margin` px of whatever is parked there shows —
  the real neighbour window, at either kind of edge. Clicking it focuses it, and the
  existing focus path scrolls it into view.
- Cost: two half-width columns no longer reach the screen edges; 2 × margin of strip
  ends or background shows. `margin = 0` restores flush.

### 2. Edge previews (new `src/EdgePreview.vala`)

- **Detection.** A capture-phase stage action (the mechanism `Mouse.vala` uses for
  Super+scroll) watches pointer motion and always propagates: it never consumes an event.
  It arms when the pointer is within 2 px of the left or right edge of the primary
  monitor's work area, on an edge that is a screen end (not one bordering another
  monitor: the pointer crosses there), and the current strip has a column hidden beyond
  that edge.
- **Which window.** A pure core function, `hidden_beyond (LayoutResult, Rect work, Side)`,
  returns the nearest column on that side that is parked or more than half outside the
  work area, or none. The preview shows that column's active window.
- **Showing.** After 100 ms at the edge, a `Clutter.Clone` of the window actor at 15%
  scale appears flush against the edge, centred vertically on the pointer and clamped to
  the work area, in `wm.top_window_group` (where `Mouse` puts its drop indicator).
  Non-reactive. Fades in and out over `ANIM_MS` when Animate is on.
- **Hiding.** When the pointer moves more than 2 px off the edge; when a grab or drag
  begins; when a relayout leaves that column no longer hidden or changes which column is
  nearest; on a workspace switch; when the window's actor is destroyed (handled on the
  actor's `destroy`, as `FocusRing` does).
- **Clicking.** No new code: at the very edge the pointer is over the neighbour's peeking
  strip, the clone passes clicks through, and Mutter's click-to-focus plus the existing
  scroll-to-focus bring the window into view. Verified in the headless test (below).
- **Never shown** with tiling off, on an untiled workspace, while the focused window is
  fullscreen, in the multitasking view, or with `edge-preview` off.

### 3. Settings

New keys in `io.github.arsfeld.paper`, both read live:

| Key | Type | Range | Default | Meaning |
|-----|------|-------|---------|---------|
| `margin` | i | 0–100 | 20 | Space kept between a focused column and the screen edge, where the neighbour peeks in |
| `edge-preview` | b | | true | Show a thumbnail of the hidden window when the pointer rests at a screen edge |

- Tiling page (`plug/LayoutPage.vala`): a Margin slider under Gap; an "Edge previews"
  switch beside Animate and Focus ring.
- Indicator popover (`indicator/Popover.vala`): a Margin slider next to Gap only.
- `src/Config.vala` maps both into `Params` / the controller; `src/Demo.vala`'s settings
  step list can set them.
- `debian/pantheon-paper.gschema.override` needs no change: it overrides only Pantheon's
  keys, and the new defaults ship in the schema.
- README: the settings list and a short "edges" paragraph.

## Testing

- Core unit tests (`meson test`):
  - presets and full width at margin 0 (identical to today) and 20; two ½ columns spanning `U − gap`;
  - `scroll_to_focus` stopping at the margin lines on both sides; an over-wide column
    centred; the first column starting at `margin`;
  - a column parked against a monitor edge leaving a `margin`-wide visible strip;
  - `hidden_beyond` at both ends, against a monitor edge, and for a strip that fits.
- Headless Gala (`just pantheon::paper-run`):
  - `PAPER_DEMO=4`: the `paper-demo: at …` frames show the margin; `paper-shot` of each
    end shows the neighbour peeking.
  - `paper-inject` moves the pointer to the right edge: the demo log reports the preview
    (a new `|| preview:` field, like `|| ring:`) and a shot shows the thumbnail; a click
    at edge − 1 focuses the hidden window and the log shows it scrolled into view.
  - `PAPER_MONITORS=2`: the peek shows at the inner edge and no preview arms there.
- On raider after deploy (logout/login): the Margin slider in the indicator and the
  Settings page, the Edge previews switch, and both behaviours on the live desktop.

## Out of scope

- PaperWM's dwell-to-activate timeout and its continual-activation variant.
- Previews at an edge bordering another monitor.
- A vertical margin.
