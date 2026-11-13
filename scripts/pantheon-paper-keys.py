#!/usr/bin/env python3
"""Fail if a pantheon-paper keybinding shares an accelerator with any other
binding, as a built system would resolve them: its dconf defaults, its schema
overrides and Pantheon's desktop-specific values. Run through
`just pantheon::paper-keys-check`, which sets that environment up.

Reads `gsettings list-recursively` output on stdin."""
import re
import sys

PLUGIN = "io.github.arsfeld.paper.keybindings"
ALIASES = {"ctrl": "control", "primary": "control", "control": "control",
           "super": "super", "shift": "shift", "alt": "alt", "mod1": "alt", "mod4": "super"}


def norm(accel):
    mods = sorted(ALIASES.get(m.lower(), m.lower()) for m in re.findall(r"<([^>]+)>", accel))
    key = re.sub(r"<[^>]+>", "", accel).lower()
    return "+".join(mods + [key]) if key else None


owners = {}
for line in sys.stdin:
    parts = line.rstrip("\n").split(" ", 2)
    if len(parts) < 3 or not parts[2].startswith(("[", "@as")):
        continue
    for accel in re.findall(r"'([^']*)'", parts[2]):
        if "<" in accel or len(accel) > 1:
            n = norm(accel)
            if n:
                owners.setdefault(n, set()).add(f"{parts[0]} {parts[1]}")

clashes = 0
for accel, who in sorted(owners.items()):
    mine = {w for w in who if w.startswith(PLUGIN)}
    others = who - mine
    if mine and others:
        clashes += 1
        print(f"{accel}: {', '.join(sorted(mine))} <-> {', '.join(sorted(others))}")
print(f"{clashes} clash(es)")
sys.exit(1 if clashes else 0)
