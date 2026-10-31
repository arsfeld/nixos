# Visual testing of Pantheon desktop changes on the live session (raider).
#
# The loop: build a patched component, swap it into the session with
# `dock-run`, open the thing to look at through a test hook (never through
# input injection, see CLAUDE.md), capture it with `shot`, read the PNG,
# change the code, repeat.

PYTHON_EXPR := "(builtins.getFlake (toString " + justfile_directory() + ")).inputs.nixpkgs.legacyPackages.x86_64-linux"

# Capture the live screen, or the area x y w h (physical pixels), to OUT.
shot out *area:
    #!/usr/bin/env bash
    set -euo pipefail
    py=$(nix build --no-link --print-out-paths --impure --expr '({{ PYTHON_EXPR }}).python3.withPackages (p: [p.pygobject3])')
    glib=$(nix build --no-link --print-out-paths --impure --expr '({{ PYTHON_EXPR }}).glib.out')
    GI_TYPELIB_PATH="$glib/lib/girepository-1.0" "$py/bin/python3" '{{ justfile_directory() }}/scripts/pantheon-shot.py' '{{ out }}' {{ area }}

# Replace the session's dock with raider's build from this checkout, passing
# any VAR=value environment through (e.g. DOCK_STACKS_OPEN=0,
# G_MESSAGES_DEBUG=all). Logs go to LOG.
dock-run log="/tmp/io.elementary.dock.log" *env:
    #!/usr/bin/env bash
    set -euo pipefail
    dock=$(nix build --no-link --print-out-paths '{{ justfile_directory() }}#nixosConfigurations.raider.pkgs.pantheon.elementary-dock')
    schemas="$dock/share/gsettings-schemas/elementary-dock-8.3.3/glib-2.0/schemas"
    # `pgrep -x` cannot match: the process name is longer than 15 characters.
    pattern='(^|/)io\.elementary\.dock$'
    # The session respawns the stock dock the moment one dies, and a second
    # dock exits silently, so kill and start in the same breath, then make sure
    # ours is the one left.
    pkill -f "$pattern" || true
    env GSETTINGS_SCHEMA_DIR="$schemas" {{ env }} setsid "$dock/bin/io.elementary.dock" > '{{ log }}' 2>&1 < /dev/null &
    for _ in $(seq 20); do
        sleep 0.5
        running=$(pgrep -fa "$pattern" || true)
        if [ "$(wc -l <<< "$running")" -eq 1 ] && grep -q "$dock" <<< "$running"; then
            echo "running $dock"
            exit 0
        fi
    done
    echo "the session's dock won the race; run again" >&2
    pgrep -fa "$pattern" >&2 || true
    exit 1
