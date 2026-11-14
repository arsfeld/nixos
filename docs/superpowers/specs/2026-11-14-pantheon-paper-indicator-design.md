# pantheon-paper: a panel indicator and a settings page

## Goal

Make pantheon-paper configurable from Pantheon itself instead of only from dconf and
nix. A Wingpanel indicator holds what is changed often (tiling on or off, for the
session or one workspace; floating the window in front; the gap; animation) and shows
the shortcuts. A System Settings (Switchboard) page holds the rest: layout values,
per-app rules and shortcut editing.

Today the plugin has one schema, `io.github.arsfeld.paper.keybindings`; the gap, the
width presets and the animation are compile-time constants
(`src/core/Types.vala`, `Preset` in `src/core/Strip.vala`).

This supersedes one decision of `2026-11-12-pantheon-paper-design.md`, "Always on, every
workspace. No per-workspace or global mode switch": both switches now exist.

## Decisions

- **Everything lives in `arsfeld/pantheon-paper`.** The plugin, its schemas, the
  indicator and the plug change together, and the elementary OS 8 `.deb` ships all three
  from one source package. Each is a meson option (`plugin`, `indicator`, `plug`, all
  enabled by default).
- **Popover for the frequent things, a Switchboard plug for the rest.** That is
  elementary's own split (Sound, Keyboard). A rule list and key capture do not fit a
  popover.
- **GSettings for configuration, D-Bus for live session state.** Saved values go in a
  new schema that the plugin follows through `changed`, so `gsettings`, dconf and nix can
  set them and the settings UIs work while the plugin is not loaded. What only Gala knows
  (the current workspace, the focused window, whether it floats) goes through a small
  D-Bus interface the plugin exports. Faking those as GSettings keys was rejected:
  Pantheon's workspaces are dynamic, so a saved list of workspace indices goes stale, and
  a "float the focused window" key would be an RPC in disguise.
- **The per-workspace switch lasts for the session**, for the same reason: there is
  nothing stable to save it against.
- **Turning tiling off releases windows where they are.** Visible windows do not move.
  Parked windows (the 75 px slivers) move just far enough to be fully on screen, or they
  would be stranded off the edge. Turning it back on adopts windows left to right by
  their current x position.
- **The sliver (75 px) and the drag-detach distance (100 px) stay constants.** The sliver
  is Mutter's number, not a preference; the detach distance has no reason to vary.
- **It builds against Mutter 46 and elementary OS 8 too**, as the plugin already does:
  wingpanel 8, switchboard-3 with GTK 4 and granite-7.

## Settings: `io.github.arsfeld.paper`

A new schema at `/io/github/arsfeld/paper/`, installed beside the keybindings one, which
is unchanged (the Debian override and the nix dconf refer to it).

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `b` | `true` | Tiling for the session. |
| `gap` | `i` (range 0–48) | `8` | Space between columns and between stacked windows, in logical px. Replaces `const GAP`. |
| `width-presets` | `ad` | `[0.3333333333, 0.5, 0.6666666667]` | Widths `cycle-width` steps through, as fractions of the work area. |
| `default-width` | `d` | `0.5` | Width of a new column; snaps to the nearest preset. |
| `animate` | `b` | `true` | Layout animations. ANDed with `org.gnome.desktop.interface enable-animations`. |
| `app-rules` | `a(sbdb)` | `[]` | Per-app rules: (app id, float, initial width, own column). Initial width `0` means the default, `1` full width, otherwise a fraction that snaps to the nearest preset. |

`width-presets` is valid with 2 to 6 entries, each in [0.1, 1.0], strictly increasing.
An invalid value (written by hand) is logged once and the defaults are used; the plug
never writes one.

`Preset` stops being an enum and becomes an index into `width-presets`. A column keeps
its index when the list changes, clamped to the last entry if the list got shorter.
`cycle-width` wraps from the last preset to the first, as now.

An app id in a rule matches, case-insensitively, the window's GTK application id, its
sandboxed app id, or its WM_CLASS (`Meta.Window.get_gtk_application_id`,
`get_sandboxed_app_id`, `get_wm_class`). The first matching rule wins.

## The plugin

- **`Config`** (`src/Config.vala`) owns the schema: it looks it up before
  `new Settings`, as `Keys` does, because a missing schema aborts the process, which is
  the session. Without it the built-in defaults apply. It exposes typed values and one
  `changed` signal; the controller relays out on it (animated if animations are on).
- **Global off.** `Controller` drops every strip and stops placing windows; windows stay
  tracked so turning tiling on again can adopt them. The parked-window move uses the same
  user-op `move_resize_frame` as layouts.
- **Per-workspace off.** A session-only `Gee.HashSet<Meta.Workspace>` of workspaces whose
  strips are dropped and whose new windows are not tiled. A workspace removed by Gala is
  pruned from it, as strips already are.
- **Rules** are pure code in the core, unit-tested:
  - *float*: a new `WindowFacts.rule_float`, so `should_tile` stays the one predicate;
  - *initial width*: applied only for `Reason.CREATED`; later re-entries (fullscreen,
    unminimize) keep using the saved slot;
  - *own column*: a `SoloCheck` interface handed to `Strip`, like `WidthHints`. `slurp`
    does not pull a solo window and does not pull anything into a solo column, and a
    drop into a solo column, or of a solo window into a column, becomes a new column.
- **D-Bus.** The plugin owns `io.github.arsfeld.Paper` on the session bus, object
  `/io/github/arsfeld/Paper`, interface `io.github.arsfeld.Paper`:

  | Member | Kind | Meaning |
  |---|---|---|
  | `WorkspaceTiled` | property `b`, read/write | Tiling on the active workspace. |
  | `FocusedFloating` | property `b`, read/write | Whether the focused window floats; writing it is `toggle-float`. |
  | `FocusedApp` | property `(ss)`, read | App id and display name of the focused window, `("", "")` if none. |
  | `RunningApps` | method `→ a(ss)` | App id and name of every tracked normal window, de-duplicated. |

  Changes are announced with `org.freedesktop.DBus.Properties.PropertiesChanged`.
  "Focused" means the last focused *normal* window: opening the indicator's popover can
  move Mutter's focus to Wingpanel, and that must not count. Verify in the headless Gala
  which way it goes before relying on either. The name is released in `destroy`.

## The indicator

`indicator/`, GTK 3 with wingpanel and granite, the way `packages/wingpanel-indicator-tailscale` is
built. Its icon shows one of three states: tiling, this workspace off, tiling off.

The popover, top to bottom:

- switches **Tiling** (`enabled`), **Tile this workspace** (`WorkspaceTiled`) and
  **Float "<window>"** (`FocusedFloating`, labelled with `FocusedApp`'s name);
- a **Gap** slider (`gap`) and an **Animate** switch (`animate`);
- **Shortcuts**, a sub-page listing every action with its current accelerator, read from
  the keybindings schema and formatted with granite;
- **Add rule for "<app>"…**, which opens the plug on the rule page with that app id;
- **Tiling Settings…**, which opens `settings://paper`.

If `io.github.arsfeld.Paper` has no owner, the live switches are insensitive with "Tiling
plugin not running — log out and back in". The settings controls still work, since they
write GSettings. The indicator watches the name, so it recovers when Gala restarts.

## The settings page

`plug/`, a Switchboard plug (GTK 4, granite-7, switchboard-3) in the Personal category,
titled "Tiling", supporting `settings://paper`, `settings://paper/rules` and
`settings://paper/shortcuts`. Three pages:

- **Layout:** the enabled switch, the gap, the width presets as an editable list of
  percentages (add, remove, reorder by value; invalid entries are refused in the UI), the
  default width (a dropdown of the presets), animate.
- **App Rules:** one row per rule with the app's name and id, a float switch, an initial
  width dropdown (default, each preset, full width) and an own-column switch, plus delete.
  "Add" offers the running apps from `RunningApps` and a field for typing an id. A rule
  with every option at its default is removed rather than kept.
- **Shortcuts:** one row per action in `Actions.NAMES` order with its accelerators. Click
  to capture a new one; Escape cancels, Backspace clears. A clash names the other action
  and its schema and offers **Replace** (unbind it there) or **Cancel**. Mutter follows
  keybinding settings live; confirm that in the headless Gala.

## Shared code

`src/common/`, GLib only, compiled into the plugin, the indicator, the plug and the
tests:

- reading and validating `width-presets`, snapping a fraction to a preset;
- rule parsing and matching;
- accelerator normalisation and the clash check against the keybinding schemas
  `tools/keys-check.py` checks: a port of that script's logic, which stays for CI.

## Build and packaging

- **meson:** options `plugin`, `indicator`, `plug` (booleans, default `true`). The "no
  supported mutter" error applies only with `plugin` on.
- **nix:** `packages/pantheon-paper` stays one derivation, now also built with gtk3,
  gtk4, granite, granite7, wingpanel and switchboard. `modules/desktop/pantheon-paper.nix`
  adds it to `services.desktopManager.pantheon.extraWingpanelIndicators` and
  `extraSwitchboardPlugs` beside `systemPackages` and `extraGSettingsOverridePackages`.
  If wingpanel's or switchboard's wrapper picks up the plugin's other files badly, split
  outputs then, not before.
- **Debian:** one `pantheon-paper` package with the extra Build-Depends
  (`libwingpanel-dev`, `libswitchboard-3-dev`, `libgtk-3-dev`, `libgtk-4-dev`,
  `libgranite-dev`, `libgranite-7-dev`). `ci/check-install.sh` also checks that the
  indicator sits in `/usr/lib/x86_64-linux-gnu/wingpanel/` and the plug in
  `/usr/lib/x86_64-linux-gnu/switchboard-3/personal/`, both linking cleanly, and that
  the new schema is compiled in.

## Testing

- **Core unit tests:** presets parsing, validation and snapping; index clamping when the
  list shrinks; rule matching; the solo rules for slurp and drop; left-to-right
  re-adoption order; the accelerator clash check.
- **Headless Gala** (`just pantheon::paper-run`, private bus), asserting on the
  `paper-demo` frame lines while driving `gsettings set` and `gdbus call` on that bus:
  tiling off then on; one workspace off; a float rule and a width rule for a new demo
  window; a live gap change; a live preset change; a live rebind; the focus question
  above.
- **Indicator and plug:** unit tests for their models (state from settings plus D-Bus,
  rule editing). They run in their own processes, so a crash restarts Wingpanel or closes
  Settings and never ends the session. They are checked by hand on raider after deploy.

## Docs

The plugin's README (keys, settings, indicator), and the "Pantheon tiling" section of
this repo's CLAUDE.md: the indicator, the plug and the new schema.
