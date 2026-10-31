#!/usr/bin/env python3
"""Capture the live Pantheon screen, or an area of it, without user interaction.

Gala serves org.gnome.Shell.Screenshot only to the owner of the
io.elementary.screenshot bus name (the Screenshot app) or of the portal
backend; anyone else gets AccessDenied. This script briefly owns that name.
grim cannot help: Gala has no wlr-screencopy. Run it through
`just pantheon::shot`, which supplies a Python with PyGObject.

usage: pantheon-shot.py OUT.png [x y w h]
Coordinates are physical pixels. The pointer is drawn only into full-screen captures;
area captures never include it, and do not flash the screen.
"""
import subprocess
import sys
import time

from gi.repository import Gio, GLib

out = sys.argv[1]
area = [int(v) for v in sys.argv[2:6]]

bus = Gio.bus_get_sync(Gio.BusType.SESSION)

# While the monitors are blanked (idle power-save) or the session is locked,
# every capture is solid black or the lock screen, yet reports success. The
# user has agreed to captures waking the display and ending the lock, so do
# that first and verify it took.
def power_save_mode():
    return bus.call_sync(
        "org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
        "org.freedesktop.DBus.Properties", "Get",
        GLib.Variant("(ss)", ("org.gnome.Mutter.DisplayConfig", "PowerSaveMode")),
        None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]


def loginctl(*args):
    # --no-ask-password: never let polkit pop a password dialog on the user's
    # screen (a bare `unlock-sessions` does exactly that, and hangs).
    return subprocess.run(["loginctl", "--no-ask-password", *args],
                          capture_output=True, text=True, check=False).stdout.strip()


# Pantheon locks in-session; the capture would show the lock screen. Unlock
# the seat's active session, which is the one on screen.
session = loginctl("show-seat", "seat0", "-p", "ActiveSession", "--value")
if session and loginctl("show-session", session, "-p", "LockedHint", "--value") == "yes":
    loginctl("unlock-session", session)
    time.sleep(2)
    if loginctl("show-session", session, "-p", "LockedHint", "--value") == "yes":
        sys.exit(f"session {session} stayed locked; captures would show the lock screen")
if power_save_mode() != 0:
    bus.call_sync(
        "org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
        "org.freedesktop.DBus.Properties", "Set",
        GLib.Variant("(ssv)", ("org.gnome.Mutter.DisplayConfig", "PowerSaveMode", GLib.Variant("i", 0))),
        None, Gio.DBusCallFlags.NONE, -1, None)
    time.sleep(2)  # let the outputs come back and redraw
    if power_save_mode() != 0:
        sys.exit("display stayed in power-save; captures would be black")

reply = bus.call_sync(
    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "RequestName", GLib.Variant("(su)", ("io.elementary.screenshot", 4)),  # DO_NOT_QUEUE
    None, Gio.DBusCallFlags.NONE, -1, None)
if reply.unpack()[0] not in (1, 4):  # PRIMARY_OWNER or ALREADY_OWNER
    sys.exit("io.elementary.screenshot is owned by another process (close the Screenshot app)")

if area:
    # (x, y, w, h, flash, filename): no flash, so the user's screen does not blink.
    method, args = "ScreenshotArea", GLib.Variant("(iiiibs)", (*area, False, out))
else:
    method, args = "Screenshot", GLib.Variant("(bbs)", (True, False, out))

ok, used = bus.call_sync(
    "org.gnome.Shell.Screenshot", "/org/gnome/Shell/Screenshot", "org.gnome.Shell.Screenshot",
    method, args, None, Gio.DBusCallFlags.NONE, -1, None).unpack()
print(used if ok else "failed")
sys.exit(0 if ok else 1)
