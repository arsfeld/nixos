# Changing and visually testing Pantheon's dock

The dock's code lives in github.com/arsfeld/elementary-dock, branch `extras`
(`packages/elementary-dock-extras`). That repo's `CLAUDE.md` holds what is about the code: how
the branch is kept, its test hooks, the Vala pitfalls, icon resolution, GTK and elementary's
icons. This file is what is about raider and nixos: the visual loop, deploying, and AppCenter.
`default.nix` here puts the package in place of `pantheon.elementary-dock`; keep it the only
override of the dock.

## Look at your own work: the visual loop

A build that compiles and unit tests that pass tell you nothing about how the dock looks.
The stacks fan passed review twice and was badly wrong on screen. Iterate against the live
session on raider instead:

```bash
just pantheon::dock-run /tmp/dock.log ~/Code/elementary-dock-extras DOCK_STACKS_OPEN=0   # build a fork checkout, swap it in
just pantheon::dock-run /tmp/dock.log "" DOCK_ZOOM_AT=3    # or the pinned rev
just pantheon::shot out.png 1000 300 1500 1140             # capture an area (physical px)
```

Then read the PNG and repeat. The screen is 3440×1440 and the dock sits bottom-centre.

- **`shot` is the only capture that works.** Gala has no wlr-screencopy, so `grim` fails.
  Its `org.gnome.Shell.Screenshot` answers only the owner of the `io.elementary.screenshot`
  bus name. `scripts/pantheon-shot.py` briefly owns that name. `io.elementary.screenshot -s`
  pops up a save dialog, so it is no use unattended.
- **A blanked or locked screen captures as black (or the lock screen),** and the call still
  reports success. The user has agreed that captures may wake and unlock raider, so the
  script does both first and verifies them:
  - It unlocks seat0's active session with
    `loginctl --no-ask-password unlock-session <id>`. A bare `loginctl unlock-sessions` pops
    a polkit password dialog on the user's screen and hangs, so never use it.
  - It sets Gala's `PowerSaveMode` to 0.
- **Never inject input.** ydotool's `--absolute` is a series of relative moves bent by pointer
  acceleration, so it misses, and it moves the pointer of the person working at the machine.
  Open what you need to see through the dock's test hooks (`DOCK_STACKS_OPEN`,
  `DOCK_STACKS_CLICK`, `DOCK_STACKS_FOLDER`, `DOCK_STACKS_FAKE_JOB`, `DOCK_STACKS_MENU`,
  `DOCK_STACKS_DROP`, `DOCK_ZOOM_AT`), passed as
  `VAR=value` arguments to `dock-run`; the fork's `CLAUDE.md` says what each does.
- **`dock-run` touches only the session's docks:** those whose `WAYLAND_DISPLAY` is the
  caller's (default `wayland-0`). A headless Gala, such as `paper-run`'s on `paper-0`, runs its
  own dock, which is left alone.
- **Swapping the dock is a race.** The session respawns the stock dock the instant one dies,
  and a second dock exits silently. `dock-run` kills and starts in one breath, then checks
  that exactly one dock runs and that it is this build.
  - `pgrep -x io.elementary.dock` never matches, because the name is over 15 characters.
    Match with `pgrep -f '(^|/)io\.elementary\.dock$'`.
  - The gsettings schemas for a dock build are under
    `$DOCK/share/gsettings-schemas/<name>-<version>/glib-2.0/schemas`, not under the
    store basename. `dock-run` globs that directory and fails unless exactly one matches.
  - `dock-run` takes `VAR=value` arguments as separate positional arguments, so a value with
    spaces survives when the argument is quoted.
  - A key the stock schema lacks (`stacks`) can be set only with that directory in
    `GSETTINGS_SCHEMA_DIR`.
  - Values set by hand land in the user dconf database and shadow the Nix default. Reset
    them after the deploy, in the order below.

## After deploying a dock change

`DCONF_PROFILE` and `NIX_GSETTINGS_OVERRIDES_DIR` are store paths the session copies at
login, so new schema keys and dconf defaults reach the session only after the user logs out
and back in. A dock restarted in the old session runs the new binary against the old schema.
`StackStore.read_stacks` and `ZoomController`'s construct make that harmless for `stacks` and the zoom keys (one warning, no stacks, dock stays
up), but any other new key needs the same `settings_schema.has_key` guard, because GLib aborts
on an unknown key.

Reset hand-set values with `dconf reset /io/elementary/dock/<key>` (run it from a login shell,
so the Pantheon `DCONF_PROFILE` applies), but only once the dock reads the new profile.
Resetting while the session still holds the old profile leaves nothing behind the key: the old
profile carries no default for it. That emptied the stacks right after the first deploy.

So the order is: deploy, then re-login (or restart the deployed dock with the login shell's
`DCONF_PROFILE` and `NIX_GSETTINGS_OVERRIDES_DIR`), then reset.

## Where stack progress comes from

- **Downloads** come from the folder itself: partial files (`.part`, `.crdownload`,
  `.download`) are entries, refreshed once a second. Only Chromium browsers also send a
  fraction, as Unity LauncherEntry (`LauncherProgress.vala`); Zen and Firefox send nothing,
  so their downloads pulse.
- **Applications** progress comes from AppCenter, through a local patch
  (`appcenter/progress.patch`) that adds `JobChanged` and `GetJobs` to its D-Bus object
  (`AppCenterJobs.vala` reads them). Bazaar, nix-flatpak and the `flatpak` CLI publish
  nothing. An AppCenter without the patch (a session started before the deploy) just
  shows no progress.
- The AppCenter daemon (`io.elementary.appcenter --silent`) keeps running the old binary
  until the next login, like the dock's schema.
