# Dock stacks for the elementary dock

Status: design approved 2026-10-31. Hosts: raider, blackbird (both `constellation.desktop.variant = "pantheon"`).

## Goal

Recreate the two macOS dock folder stacks on Pantheon's dock:

- **Downloads**: the icon previews the newest files and updates live. Clicking it fans the
  files out in an arc, with the most recent one nearest the dock.
- **Applications**: clicking it opens a scrollable grid of every installed app, A–Z.

Both are one generic item type with different config.

## Constraint: the dock has no applets

`elementary-dock` 8.3.3 (`pantheon.elementary-dock`) has no plugin or applet system. Its
items are pinned launchers (`launchers` gsettings key), the background-apps item and
workspaces. Its D-Bus interface (`io.elementary.dock.items`) only adds and removes
launchers. A live preview icon can only be drawn by the dock itself, so this is a
**local patch to the dock**, applied with `overrideAttrs`. A standalone popup app pinned
as a launcher was rejected: it cannot draw a live icon, and Gala on Wayland does not let an
ordinary window anchor itself to the dock. A fork of `elementary/dock` was rejected because
a patch file in this repo does the same and lives next to the config.

## Configuration

The patch adds a gsettings key to `data/dock.gschema.xml`:

```
io.elementary.dock stacks : a(ssss)   default []
```

Each tuple is `(source, view, sort, display)`:

| field     | values                                                                 |
|-----------|------------------------------------------------------------------------|
| `source`  | an absolute path (a leading `~/` is expanded), or the literal `applications` |
| `view`    | `fan` or `grid`                                                        |
| `sort`    | `date-added` (newest first) or `name` (A–Z)                            |
| `display` | `stack` (live preview of the first entries) or `folder` (static icon)  |

The dock watches `changed::stacks` and rebuilds its stack items, the same way it watches
`launchers`.

`date-added` sorts by `time::created` where the filesystem provides it and falls back
to `time::modified`. GIO exposes no true "date added".

### Nix side

In `modules/constellation/pantheon-dock/default.nix`, the one module for every local dock
patch (as built; the design first placed this in `desktop.nix`):

- An overlay replaces `pantheon.elementary-dock` through `pantheon.overrideScope`, adding
  `pantheon-dock/stacks/hooks.patch` to `patches` and copying `pantheon-dock/stacks/src/`
  into the dock's `src/Stacks/`. haumea loads only `.nix` files, so the Vala sources and
  the patch sit beside the module unharmed.
- A new option, `constellation.desktop.pantheon.dockStacks`, is a list of submodules
  `{source, view, sort, display}` with the defaults `view = "grid"`, `sort = "name"`,
  `display = "stack"`. It is written as a system dconf default for `io/elementary/dock/stacks`
  in the Pantheon dconf profile the module already generates.
- raider and blackbird set:

```nix
constellation.desktop.pantheon.dockStacks = [
  { source = "~/Downloads"; view = "fan"; sort = "date-added"; }
  { source = "applications"; view = "grid"; sort = "name"; }
];
```

## Components (Vala, all new files except the hook in `ItemManager.vala`)

### `StackSource`

Exposes a sorted `ListModel` of entries (`GFileInfo` for folders, `GAppInfo` for
applications) and a `missing` property.

- **Folder backend**: enumerates the directory, keeps it current with a
  `GFileMonitor`, and sorts with a `GtkSortListModel`. It skips hidden files and
  in-progress downloads (`*.part`, `*.crdownload`, `*.download`).
- **Applications backend**: `AppInfo.get_all ()` filtered by `should_show ()`, sorted
  case-insensitively by display name, refreshed on `AppInfoMonitor.changed`.

### `StackItem : BaseIconGroup`

One dock item per configured stack, in a new `ItemGroup` that `ItemManager` appends
after the app launchers and before the background-apps item and workspaces.

- **`display = stack`**: the `icons` model maps the first entries of the source to icons,
  and `BaseIconGroup`'s existing renderer draws the cluster. Files use the thumbnail from
  GNOME's thumbnail cache (`thumbnail::path`) when one exists and their content-type icon
  otherwise. Apps use the app icon.
- **`display = folder`**: a single static icon, `folder-download` for `~/Downloads`,
  `applications-other` for `applications`, and the directory's own icon for any other
  folder.
- The tooltip is the folder's display name, or "Applications".
- A click toggles the popover for its `view`.

### `FanPopover`

A transparent `Gtk.Popover` (`position = TOP`, offset `(0, -1)`, as `BackgroundItem`
does) holding a custom widget.

- It shows the newest 10 entries as icon and label pairs, laid out on an arc rising from the
  dock icon. Each one is rotated a few degrees more than the last in `snapshot ()`. Entry 0,
  the newest, is at the bottom, nearest the dock.
- Above the arc: **Open in Files** and, when there are more than 10 entries,
  **N more…**. Both open the folder with its default handler.
- Fallback if Gala or the theme draws a frame or shadow around a transparent popover: keep
  the default framed popover with the same arc inside it.

### `GridPopover`

A framed popover holding a `Gtk.GridView` in a `Gtk.ScrolledWindow`, sized to about 6
columns × 5 rows of visible cells and scrolled with the wheel. No search field: elementary's
Applications menu already handles search. It works for any source, so a folder with
`view = grid` also works.

### Interaction

- Activating an entry closes the popover and launches it: files through
  `AppInfo.launch_default_for_uri`, apps through `launch`, both with the display's launch
  context.
- File entries carry a `Gtk.DragSource` with the file URI, so they can be dragged out of
  the fan or grid.
- **Out of scope:** dropping files onto a stack, right-click menus, dragging stacks to
  reorder them, and editing stacks from the dock. Stacks are configured in Nix only.

## Error handling

- Missing folder: a dimmed `folder` icon, and the popover shows "Folder not found".
- Unknown `source`/`view`/`sort`/`display` value: log with `warning ()` and skip that stack.
  The rest of the dock is unaffected.
- A launch failure is logged with `critical ()`, as `BackgroundItem` already does.

## Testing

1. `nix build .#nixosConfigurations.raider.config.system.build.toplevel`: the patch
   applies and the dock compiles.
2. A NixOS VM check in `flake-modules/checks.nix` boots Pantheon with two stacks set and
   asserts that `io.elementary.dock` is still running and its journal has no `stacks`
   warnings. A second case, with an invalid entry, asserts the warning is logged and the
   dock is still up.
3. Manual, on raider after `just deploy raider`:
   - take screenshots of both popovers;
   - download a file and watch the Downloads preview and fan update;
   - drag a file out of the fan into a browser upload.

## Maintenance

The patch must be rebased whenever nixpkgs bumps `elementary-dock`. The weekly update
routine sees that as a build failure, and fixes or reverts it the same way it handles
`packages/`. To keep rebases small, the patch is additive: new source files, the
`meson.build` source list, the schema key, and about 10 lines in `ItemManager.vala`.
