# Dock stacks: app folders, download progress, Flathub progress

Status: design approved 2026-10-31. Hosts: raider, blackbird (`constellation.desktop.variant = "pantheon"`).
Builds on `2026-10-31-dock-stacks-design.md` and `2026-10-31-dock-stacks-polish-design.md`.

## Goal

Three additions to the dock stacks:

1. **Applications** groups its apps into folders, so the everyday apps are what the grid shows
   first instead of 150 entries A–Z.
2. **Downloads** shows downloads in progress, on the tile and in the fan.
3. **Applications** shows Flathub installs, updates and removals in progress.

## Why folders, and not AppStream ranking

The request was to put flatpaks and apps with proper AppStream metadata first. Measured on raider
(150 visible apps): 42 flatpaks, 72 Nix apps and 36 local entries (mostly game shortcuts and wine
helpers); 78 have metainfo. AppStream is a poor quality signal here, because nixpkgs often drops
it: Firefox, VS Code, Zed, Discord, Heroic, Claude, LocalSend and Sublime Merge have none.
Ranking on it would demote apps used every day.

Desktop `Categories` are nearly universal (147 of 150: Game 46, Utility 26, System 21, Network 21,
AudioVideo 14, Office 10), and they are what every launcher uses to group:

- GNOME Shell: one A–Z grid plus *System* and *Utilities* folders, extensible via
  `org.gnome.desktop.app-folders` (categories plus include and exclude lists).
- COSMIC App Library: Home plus *Office*, *System*, *Utilities* groups, each a `Categories`
  filter with include and exclude lists.
- elementary's Applications Menu: a grid view and a category view, with hard-coded mappings
  from `Categories`.
- macOS Tahoe's Apps: A–Z with a category filter. iOS App Library: automatic store categories.

No launcher filters on AppStream. Only the software centres need it, for what they can manage.

## 1. Applications folders

### Classification (`AppFolders.vala`, hard-coded)

Each visible app (`AppInfo.should_show ()`) maps to a folder, or to none. The first matching rule
wins:

| Folder         | Rule                                                                           |
|----------------|--------------------------------------------------------------------------------|
| Terminal Tools | `Terminal=true`                                                                |
| Games          | `Game` in `Categories`                                                         |
| System         | `System` or `Settings` in `Categories`                                         |
| Utilities      | `Utility`, and none of `AudioVideo`, `Audio`, `Video`, `Development`, `Education`, `Graphics`, `Network`, `Office`, `Science` |
| top level      | everything else, including apps with no category                               |

Folders are not configurable: there is no gsettings key and no Nix option. A change means editing
the patch. Flatpak and AppStream status play no part in classification or order.

### Model

- `StackEntry` gains a folder kind. A folder entry has a name, a `ListStore` of its child entries
  sorted A–Z, and no `file` or `app`.
- For `source = applications` with `view = grid`, `StackSource`'s top-level model is the
  unfoldered apps A–Z, followed by the non-empty folders in the table's order (Games, System,
  Utilities, Terminal Tools; they come after the apps regardless of name).
- With `view = fan`, the applications source stays flat, as today.
- The tile's pile preview (`display = stack`) draws from the top-level apps only, never from
  folder entries.

### Grid

- A folder cell draws its first four children's icons as a 2×2 mini-grid in the 48 px icon slot.
  Its label is the name and the count, e.g. "Games · 46".
- Activating a folder cell slides the `GridPopover` content (a `Gtk.Stack`) to that folder's
  grid. A header row holds a back button labelled "Applications" and the folder name. Back or
  Escape returns to the top level. Closing the popover resets it to the top level.
- Cell size, 6 columns and 4 visible rows are unchanged, and apply inside a folder too.

## 2. Download progress

### Entries

The folder backend stops dropping `*.part`, `*.crdownload` and `*.download` files. It keeps them
as entries with `downloading = true`:

- The displayed name is the file name without the suffix. Chrome's `Unconfirmed 123.crdownload`
  shows as-is until the browser renames it.
- Zen and Firefox create a 0-byte placeholder with the final name next to `name.part`. While the
  `.part` exists, the placeholder is not listed, so a download never appears twice.
- An entry has a `bytes` property and a `stalled` property. While any downloading entry exists,
  the source refreshes `bytes` once per second with `query_info` on just those files, without a
  folder reload. If `bytes` hasn't changed for 60 s, the entry is stalled, which covers leftovers
  from a browser crash.
- `FileMonitor` `CHANGED` events on downloading files are ignored. Create, delete and move still
  trigger the debounced reload, so the fan does not re-lay-out on every write.
- A downloading entry sorts by its date added like any other file, so a new download is newest.

### In the fan and grid

A downloading entry has a dimmed icon, a thin progress bar under it (pulsing; there is no
per-file fraction), and a subtitle: "Downloading · 34 MB" or "Stalled · 34 MB". Activating it
opens the folder, not the half-written file. It has no drag source.

### On the tile

A progress bar is overlaid at the bottom of the tile icon, using the same widget and CSS as
upstream `Launcher`'s Unity progress bar. It shows while the stack has at least one non-stalled
downloading entry:

- **A real fraction** when `LauncherProgress` has one, i.e. the mean of the values from every app
  currently reporting progress.
- **Pulsing** otherwise. This covers Zen, which reports progress nowhere: Firefox never
  implemented the Unity LauncherEntry API.

### `LauncherProgress.vala`

A singleton that subscribes to `com.canonical.Unity.LauncherEntry` `Update` signals on the
session bus. This is independent of upstream `AppSystem`'s subscription, which it leaves alone.
It keeps the `progress` and `progress-visible` values per application URI. A value counts toward
a stack's tile only when both hold:

- the app's desktop entry lists `x-scheme-handler/https` in `MimeType` (it is a browser);
- the stack has at least one `.crdownload` entry in progress (Chromium's format; Chrome, Brave
  and Vivaldi send LauncherEntry download progress).

Everything else is ignored silently, because it is normal bus traffic.

## 3. Flathub install and update progress

### AppCenter patch (`pantheon-dock/appcenter/progress.patch`)

This patch is applied to `pantheon.appcenter` in the same `pantheon.overrideScope` overlay as the
dock patches, in `modules/constellation/pantheon-dock/default.nix`. It is additive. AppCenter's
`DBusServer` (`io.elementary.appcenter`, `/io/elementary/appcenter`) gains:

- `signal JobChanged (string component_id, string desktop_id, string name, string icon, uint state, double progress)`.
  `state` is 0 for idle or finished, 1 for installing, 2 for updating and 3 for removing.
  `icon` is `GIcon.to_string ()` of the package's cached AppStream icon, or empty if it has none.
  `desktop_id` comes from the component's `desktop-id` launchable, or is empty.
- `GetJobs () → a(ssssud)`: every job currently running, in the same field order, for a dock that
  starts or restarts mid-job.

Emission happens at `Package.perform_operation`, through which every install, update and remove
passes: once when a job starts, then on `change_information.notify["progress"]` throttled to
4 Hz, and finally once with state 0 when it ends, whether it succeeded, failed or was cancelled.
AppCenter is a single `GApplication`, so its `--silent` auto-update daemon and its window share
one `DBusServer`.

**To verify in the plan:** that automatic updates go through `perform_operation` once per app,
and how AppCenter's combined runtime or "update all" job reports. A job with an empty
`desktop_id` counts toward the tile only.

### Dock side (`AppCenterJobs.vala`)

- It uses plain GDBus: `signal_subscribe` on the owner's unique name plus a `GetJobs` call. That
  leaves upstream's `AppCenterDBus` untouched, which keeps the patch additive, and a malformed
  message is rejected with a warning.
- It watches the name without `AUTO_START`.
- On appear, it calls `GetJobs` and then follows `JobChanged`. On vanish, it clears every job, so
  an AppCenter crash never leaves a bar stuck. `clear ()` keeps `fake.` jobs (the
  `DOCK_STACKS_FAKE_JOB` hook).

### What the Applications stack shows

- **Tile:** the Section 2 progress bar, showing the mean progress of all active jobs, visible
  while any job runs.
- **Updating or removing an installed app:** the app's cell gets a dimmed icon and a bar. If the
  app is in a folder, the folder cell also shows a bar.
- **Installing a new app:** a provisional cell, using the name and icon from the signal, sits
  first at the top level, labelled "Installing", with a bar. When the job ends, it is dropped.
  The `AppInfoMonitor` reload brings in the real app, in its folder if it has one.
- Activating a busy cell opens AppCenter on that app (`appcenter://<component_id>`). Failure
  dialogs remain AppCenter's.

**Not covered:** Bazaar, nix-flatpak's activation-time installs and the `flatpak` CLI. They keep
progress in-process, and their apps appear when they finish.

## Test hooks

Like the existing hooks, these are read from the dock's environment (see
`modules/constellation/pantheon-dock/CLAUDE.md`):

- `DOCK_STACKS_FOLDER=<folder name>`: when the grid opened by `DOCK_STACKS_OPEN` is the
  Applications grid, it immediately opens that folder.
- `DOCK_STACKS_FAKE_JOB=<desktop-id>:<state>:<progress>`: injects one AppCenter job at
  startup, without AppCenter. An unknown desktop id gives a provisional "Installing" cell.

Download progress needs no hook. Write slowly into `~/Downloads/x.part` for the pulsing case.
For a fraction, also create a `.crdownload` and run
`gdbus emit --session --object-path /test --signal com.canonical.Unity.LauncherEntry.Update "application://com.google.Chrome.desktop" "{'progress': <0.4>, 'progress-visible': <true>}"`.

## Error handling

- **Old AppCenter:** if the running AppCenter has no `GetJobs`, or the call fails, the dock
  logs one `debug ()`, shows no app progress, and keeps running.
- **Malformed `JobChanged`:** logged with `warning ()` and ignored.
- **Unwanted LauncherEntry values:** ignored silently, as described in Section 2.
- **Vanished file:** a downloading file that disappears during the once-a-second refresh (renamed
  on completion) is left to the next debounced reload. Its `NOT_FOUND` is not an error.
- **Schema:** there are no new gsettings keys, so no new `has_key` guard is needed.
- **Teardown:** `LauncherProgress` and `AppCenterJobs` are long-lived singletons. Stack items
  connect to them with methods, never capturing lambdas, and disconnect:
  `StackSource.stop ()` disconnects from the singletons, and `StackItem.teardown ()` disconnects
  its own handlers. Verify with `G_MESSAGES_DEBUG=all`.

## Testing

1. **Unit tests** in `stacks/src/tests`:
   - folder classification against fixture desktop files (Terminal, Game, System/Settings, a
     mixed Utility app, no category);
   - pairing a `.part` with its placeholder, and stall detection;
   - the browser and `.crdownload` gate on LauncherEntry values;
   - parsing `JobChanged` and `GetJobs` results.
2. **Build:** `nix build .#nixosConfigurations.raider.config.system.build.toplevel`, which
   checks that both patches apply and both packages compile.
3. **Existing VM check:** still passes, with no new warnings in the dock's journal.
4. **Visual loop on raider:** `just pantheon::dock-run`, then `just pantheon::shot`, for:
   - the top-level Applications grid, and Games via `DOCK_STACKS_FOLDER`;
   - a pulsing `.part` download, and a `.crdownload` with a faked LauncherEntry fraction;
   - `DOCK_STACKS_FAKE_JOB` for an install and for an update;
   - one real install through AppCenter's existing `install` D-Bus method.

## Maintenance

There are now two patched Pantheon packages. An AppCenter bump in `nix flake update` can break
`progress.patch`. The weekly update routine sees that as a build failure and handles it as it
does the dock patch. The dock's `CLAUDE.md` gains the two new hooks, `LauncherProgress`, and a
note that the AppCenter patch lives beside the dock patches.
