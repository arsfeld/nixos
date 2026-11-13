# Dock stacks: drag a folder in, configure from a menu

Date: 2026-11-13. Code: github.com/arsfeld/elementary-dock, branch `extras`
(`packages/elementary-dock-extras`). Builds on `2026-10-31-dock-stacks-design.md`.

## Goal

Today a stack exists only if `constellation.desktop.pantheon.dockStacks` declares it, and its
view, sort and display can be changed only by editing Nix (or dconf by hand). The goal:

- Dragging a folder from Files onto the dock adds it as a stack.
- Right-clicking a stack opens a menu to change its view, sort and display, open it in Files,
  or remove it.

Success is doing both on raider with no rebuild, and the result surviving a dock restart and a
re-login.

## Decisions

- **The dock owns the list.** It writes the whole `stacks` key to user dconf on every change,
  as it already does for pinned launchers. `dockStacks` becomes the seed: it is the system
  default, which the user value shadows after the first drop or edit.
  `dconf reset /io/elementary/dock/stacks` returns to it (and is the only way to get the
  Applications stack back once removed).
- **A dropped folder is appended** after the existing stacks, with the defaults
  `fan`, `date-added`, `stack`. No live insertion gap.
- **The menu** holds View as (Fan / Grid), Sort by (Date added / Name), Display as
  (Stack / Grid preview / Folder), Open in Files, Remove from Dock.
- No drag-to-reorder of stacks.

## Design

### StackStore writes

`StackStore` gains:

- `bool add (string path)`: appends `(path, fan, date-added, stack)`; returns false, writing
  nothing, if a stack with the same resolved source exists.
- `void remove (string source)`.
- `void update (string source, View view, Sort sort, Display display)`.

Each builds the new list and writes the whole `a(ssss)` value. `StackConfig.to_variant ()`
serializes an entry, writing a source under the home directory as `~/…` (the form the Nix
option uses) and `applications` as is. The enum-to-string mapping lives next to `parse` so the
two stay inverse.

Writing checks `settings_schema.has_key ("stacks")` first, like `read_stacks`: a dock running
against a stale session schema logs a warning and changes nothing, rather than aborting in GLib.

`load ()` stops splicing the whole store. It diffs the parsed list against the current one by
`(source, view, sort, display)` and replaces only the changed range, so editing one stack does
not tear down and rebuild every other tile. A changed entry is still a fresh `StackConfig`
(they are construct-only), so its item is rebuilt; `StackItem` already tears itself down on
removal.

`StackStore` is reached through `ItemManager` (which owns it) by a public getter, so
`StackItem` can call it.

### Drop

In `ItemManager`'s existing `Gtk.DropTarget (typeof (File))`, the `notify["value"]` handler
checks the file type before trying `DesktopAppInfo`:

- A directory: remember it as `pending_folder`. If a stack for it already exists, reject the
  drop and play that stack's launch bounce.
- Otherwise the current `.desktop` path runs unchanged.

On `drop`, a `pending_folder` is passed to `StackStore.add`. `leave` clears it. The file type
is queried with `query_file_type (NONE)`, which follows symlinks, so a link to a folder counts.

### Menu

`StackItem` sets `gesture_click.button = 0` and switches on the button: primary opens the fan
or grid as today, secondary opens a `Gtk.PopoverMenu` built from a `GLib.Menu`, like
`Launcher`'s. A touch long press opens it too.

Actions live in a `SimpleActionGroup` inserted as `stack`:

- `stack.view`, `stack.sort`, `stack.display`: stateful string actions (radio items), whose
  activation calls `StackStore.update` with the one field changed.
- `stack.open`: opens the folder with the default file manager (`AppInfo.launch_default_for_uri`).
- `stack.remove`: `StackStore.remove`.

The Applications stack omits Sort by (its order is fixed by AppFolders) and Open in Files.

The menu popover is separate from `popover_menu` (which stays the fan or grid popover the zoom
code freezes on). Teardown pops it down and unparents it the same way.

## Testing

- Unit tests in `src/Stacks/tests/StackTests.vala` (display-free): `to_variant` and `parse`
  round-trip; `~/` is written for a home path and not for others; adding a duplicate is
  refused; `update` and `remove` touch only their entry; the diff in `load` keeps unchanged
  `StackConfig` objects. The store logic that the tests need is split from `Settings`, so it
  runs without a schema.
- Test hooks, documented in the fork's `CLAUDE.md`:
  - `DOCK_STACKS_MENU=<index>` opens that stack's menu 1.5 s after it is built.
  - `DOCK_STACKS_DROP=<path>` runs the folder-drop path 1 s after start.
- On raider: `just pantheon::dock-run` with each hook and `just pantheon::shot`, checking the
  menu's look and that a dropped stack appears and persists across a dock restart.

## Delivery

One new commit on `extras`, `feat: stack drag-and-drop and menu`, before the README commit;
the README and the fork's `CLAUDE.md` gain a line each. Then the rev bump in
`packages/elementary-dock-extras/package.nix`, and the `dockStacks` description in
`modules/desktop/pantheon-dock/default.nix` says it is the initial list.
