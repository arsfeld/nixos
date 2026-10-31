# Patching and visually testing Pantheon's dock

Notes for any change to `pantheon.elementary-dock` (stacks, zoom, anything after them). The
overlay that applies every dock patch is `default.nix` here; keep it
the only one. Stacks design and plan: `docs/superpowers/specs/2026-10-31-dock-stacks-design.md`,
`docs/superpowers/plans/2026-10-31-dock-stacks.md`.

## Look at your own work: the visual loop

A build that compiles and unit tests that pass tell you nothing about how the dock looks.
The stacks fan passed review twice and was badly wrong on screen. Iterate against the live
session on raider instead:

```bash
just pantheon::dock-run /tmp/dock.log DOCK_STACKS_OPEN=0   # build this checkout's dock, swap it in
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
  acceleration, so it misses. It also moves the pointer of the person working at the machine.
  Open what you need to see through a test hook instead. For the stacks that hook is
  `DOCK_STACKS_OPEN=<index into stacks>`, which pops that stack's popover about 1.5 s after each matching StackItem is built, and again
  whenever `stacks` changes (`stacks/src/StackItem.vala`). For the zoom it is `DOCK_ZOOM_AT=<slots>`, which zooms the
  dock 1 s after start as if the pointer rested that many launcher widths from its left edge
  (`ItemManager.vala` in `zoom/hooks.patch`). It fires before `DOCK_STACKS_OPEN`, so the two
  combine. Give new UI the same kind of hook.
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

## Vala pitfalls that bit here

- **Lambdas inside an `Object (...)` chain-up** are compiled as closures over a NULL `this`,
  and the result is a `g_object_unref` critical on finalize. Use a static method.
- **Dock items are never freed on their own.** `BaseIconGroup`'s `bind_model` delegate, and
  the animation callbacks behind `BaseItem.cleanup ()`, both hold the item. Upstream never
  calls `cleanup ()`. `StackItem` tears itself down when its parent goes null; anything new
  that the dock removes at runtime needs the same treatment.
- **Signal handlers on long-lived objects** (a `StackSource`, its `entries`) should be
  methods, not lambdas that capture locals. Each removal path should be verified with
  `G_MESSAGES_DEBUG=all` and the teardown/finalize debug lines.
- **valac's `warning ()` prefixes `File.vala:LINE: `.** A `Test.expect_message` pattern
  needs a leading `*`, and GLib tests make any unexpected warning fatal.

## GTK 4.22 and elementary's icons

GTK 4.22 draws 399 of elementary-icon-theme's SVGs fully transparent, including
`text-x-generic` and `application-pdf`. Those files spell the xlink namespace `nsN:`, and
GTK's own SVG renderer matches only a literal `xlink:href`. librsvg renders them fine, so
`rsvg-convert` is no test. `elementaryIconFix` in `modules/constellation/desktop.nix` ships
corrected copies. A "blank" icon anywhere in Pantheon is this before it is anything else.
