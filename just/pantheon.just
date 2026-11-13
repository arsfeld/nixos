# Visual testing of Pantheon desktop changes on the live session (raider).
#
# The loop: build a changed component, swap it into the session with
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

# Replace the session's dock with raider's build, passing any VAR=value
# environment through (e.g. DOCK_STACKS_OPEN=0, G_MESSAGES_DEBUG=all). Logs go
# to LOG. SRC is a checkout of arsfeld/elementary-dock (uncommitted changes
# included) to build in place of the pinned rev; "" builds the pinned one.
[positional-arguments]
dock-run log="/tmp/io.elementary.dock.log" src="" *env:
    #!/usr/bin/env bash
    set -euo pipefail
    # Positional arguments keep each VAR=value whole, so a value with spaces survives.
    log="$1"
    src="${2:-}"
    shift $(( $# < 2 ? $# : 2 ))
    extra=("$@")
    attr='nixosConfigurations.raider.pkgs.pantheon.elementary-dock'
    if [ -z "$src" ]; then
        dock=$(nix build --no-link --print-out-paths "{{ justfile_directory() }}#$attr")
    elif [ -d "$src" ]; then
        src=$(realpath "$src")
        dock=$(nix build --no-link --print-out-paths --impure --expr "(builtins.getFlake (toString {{ justfile_directory() }})).$attr.overrideAttrs { src = builtins.path { name = \"elementary-dock-src\"; path = $src; filter = p: t: !(builtins.elem (baseNameOf p) [\".git\" \"build\" \"dist\"]); }; }")
    else
        echo "SRC must be a checkout of arsfeld/elementary-dock, or \"\" for the pinned rev; got: $src" >&2
        exit 1
    fi
    # The directory is named after the package version; glob it, and insist on one match.
    shopt -s nullglob
    matches=("$dock"/share/gsettings-schemas/*/glib-2.0/schemas)
    if [ "${#matches[@]}" -ne 1 ]; then
        echo "expected exactly one schemas directory under $dock/share/gsettings-schemas, found ${#matches[@]}" >&2
        exit 1
    fi
    schemas="${matches[0]}"
    # `pgrep -x` cannot match: the process name is longer than 15 characters.
    pattern='(^|/)io\.elementary\.dock$'
    # Only this session's docks: a headless Gala (paper-run) has its own, on
    # another WAYLAND_DISPLAY, which must be left alone.
    display="${WAYLAND_DISPLAY:-wayland-0}"
    session_docks() {
        local pid
        for pid in $(pgrep -f "$pattern"); do
            # grep -z reads the NUL-separated file itself: piped through tr, an
            # early grep match could SIGPIPE tr and pipefail would drop the dock.
            grep -qzx "WAYLAND_DISPLAY=$display" "/proc/$pid/environ" 2>/dev/null \
                && echo "$pid $(tr '\0' ' ' < "/proc/$pid/cmdline")"
        done
        return 0
    }
    # The session respawns the stock dock the moment one dies, and a second
    # dock exits silently, so kill and start in the same breath, then make sure
    # ours is the one left.
    # A dock may exit between listing and kill; that is not a failure.
    session_docks | cut -d' ' -f1 | xargs -r kill 2>/dev/null || true
    env WAYLAND_DISPLAY="$display" GSETTINGS_SCHEMA_DIR="$schemas" "${extra[@]}" setsid "$dock/bin/io.elementary.dock" > "$log" 2>&1 < /dev/null &
    for _ in $(seq 20); do
        sleep 0.5
        running=$(session_docks)
        if [ "$(wc -l <<< "$running")" -eq 1 ] && grep -q "$dock" <<< "$running"; then
            echo "running $dock"
            exit 0
        fi
    done
    echo "the session's dock won the race; run again" >&2
    session_docks >&2
    exit 1

# Replace the session's panel with one that loads this checkout's build of
# INDICATOR (wingpanel-indicator-INDICATOR, libINDICATOR-indicator.so) in place
# of the deployed one, passing any VAR=value environment through (e.g.
# G_MESSAGES_DEBUG=all). Logs go to LOG.
[positional-arguments]
panel-run indicator="gamemode" log="/tmp/io.elementary.wingpanel.log" *env:
    #!/usr/bin/env bash
    set -euo pipefail
    name="$1"
    log="$2"
    shift 2
    extra=("$@")
    indicator=$(nix build --no-link --print-out-paths "{{ justfile_directory() }}#nixosConfigurations.raider.pkgs.wingpanel-indicator-$name")
    so="lib$name-indicator.so"
    # `pgrep -x` cannot match: the process name is longer than 15 characters.
    pattern='(^|/)io\.elementary\.wingpanel$'
    pid=$(pgrep -f "$pattern" | head -n1) || { echo "no wingpanel is running" >&2; exit 1; }
    exe=$(readlink "/proc/$pid/exe")
    # The running panel's environment, as its nix wrapper and gala set it; ours
    # differs only in WINGPANEL_INDICATORS_PATH, later on the env line, so it wins.
    mapfile -d '' session_env < "/proc/$pid/environ"
    current=$(printf '%s\n' "${session_env[@]}" | sed -n 's/^WINGPANEL_INDICATORS_PATH=//p')
    dir=$(mktemp -d /tmp/wingpanel-indicators.XXXXXX)
    for f in "$current"/*.so; do
        [ "$(basename "$f")" = "$so" ] || ln -s "$f" "$dir/"
    done
    ln -s "$indicator/lib/wingpanel/$so" "$dir/"
    # gala respawns the panel the moment one dies, and a second panel hands its
    # command line to the first and exits, so kill and start in the same
    # breath, then make sure ours is the one left. `exec -a` keeps the name
    # the pattern above matches.
    pkill -f "$pattern" || true
    env -i "${session_env[@]}" WINGPANEL_INDICATORS_PATH="$dir" "${extra[@]}" \
        setsid "$BASH" -c 'exec -a io.elementary.wingpanel "$0"' "$exe" > "$log" 2>&1 < /dev/null &
    for _ in $(seq 20); do
        sleep 0.5
        pids=$(pgrep -f "$pattern" || true)
        if [ "$(wc -w <<< "$pids")" -eq 1 ] && tr '\0' '\n' < "/proc/$pids/environ" | grep -qxF "WINGPANEL_INDICATORS_PATH=$dir"; then
            echo "running with $indicator"
            exit 0
        fi
    done
    echo "the session's panel won the race; run again" >&2
    pgrep -fa "$pattern" >&2 || true
    exit 1

# The pantheon-paper Gala plugin (github.com/arsfeld/pantheon-paper) is tested
# in a private, headless Gala with its own session bus and in-memory
# GSettings, so nothing touches the live session (a plugin cannot be swapped
# into a running Gala). Run the plugin checkout's commands inside `paper-shell`,
# which carries exactly the Gala and Mutter 48 the package builds against.
PAPER_EXPR := "(builtins.getFlake (toString " + justfile_directory() + ")).nixosConfigurations.raider.pkgs"

# Run CMD in a shell with pantheon-paper's build inputs, in the caller's directory.
[no-cd]
[positional-arguments]
paper-shell *cmd:
    #!/usr/bin/env bash
    set -euo pipefail
    exec nix develop --impure --expr '({{ PAPER_EXPR }}).callPackage {{ justfile_directory() }}/packages/pantheon-paper/package.nix {}' -c "$@"

# A Gala that loads plugins from /tmp/paper-gala-plugins instead of the system
# profile. Dev only, never installed.
paper-gala:
    @nix build --no-link --print-out-paths --impure --expr 'let p = {{ PAPER_EXPR }}; in p.pantheon.gala.overrideAttrs (o: { postPatch = o.postPatch + "\nsubstituteInPlace meson.build --replace-fail /run/current-system/sw/lib/gala/plugins /tmp/paper-gala-plugins\n"; })'

# Start a headless Gala (1920x1080) loading BUILD_DIR's libgala-paper.so,
# passing VAR=value environment through (e.g. PAPER_DEMO=4). Logs to
# /tmp/paper-gala.log; the bus address is in /tmp/paper-gala.bus. Capture with
# `just pantheon::paper-shot OUT`.
[no-cd]
[positional-arguments]
paper-run build_dir *env:
    #!/usr/bin/env bash
    set -euo pipefail
    build=$(realpath "$1"); shift
    gala=$(just -f '{{ justfile_directory() }}/justfile' pantheon::paper-gala)
    just -f '{{ justfile_directory() }}/justfile' pantheon::paper-stop
    rm -rf /tmp/paper-gala-plugins /tmp/paper-gala-schemas
    mkdir -p /tmp/paper-gala-plugins /tmp/paper-gala-schemas
    cp "$build/libgala-paper.so" /tmp/paper-gala-plugins/
    # Gala's own schemas plus the plugin's, compiled together: GSETTINGS_SCHEMA_DIR replaces the search path.
    for d in $(tr : ' ' <<< "${XDG_DATA_DIRS:-}") "$gala/share"; do
        for s in "$d"/glib-2.0/schemas/*.xml "$d"/gsettings-schemas/*/glib-2.0/schemas/*.xml "$d"/gsettings-schemas/*/glib-2.0/schemas/*.override; do
            [ -e "$s" ] && cp -n "$s" /tmp/paper-gala-schemas/ 2>/dev/null || true
        done
    done
    # Pantheon's own defaults (Super+Left switches workspaces there, not in GNOME) are
    # .override files with [schema:Pantheon] sections: copy them, and run as Pantheon.
    for s in "${NIX_GSETTINGS_OVERRIDES_DIR:-/nonexistent}"/*.xml "${NIX_GSETTINGS_OVERRIDES_DIR:-/nonexistent}"/*.override; do
        [ -e "$s" ] && cp -f "$s" /tmp/paper-gala-schemas/
    done
    cp "$build/../data/io.github.arsfeld.paper.keybindings.gschema.xml" /tmp/paper-gala-schemas/
    # PAPER_MONITORS=2 adds a second 1920x1080 monitor to the right of the primary.
    count=1
    for arg in "$@"; do [[ "$arg" == PAPER_MONITORS=* ]] && count="${arg#PAPER_MONITORS=}"; done
    monitors=()
    for _ in $(seq "$count"); do monitors+=(--virtual-monitor 1920x1080); done
    glibdev=$(nix build --no-link --print-out-paths --impure --expr '({{ PAPER_EXPR }}).glib.dev')
    "$glibdev/bin/glib-compile-schemas" /tmp/paper-gala-schemas
    # The demo hook's windows: tests/demo-window.py from the plugin checkout, a plain GTK 3 window.
    py=$(nix build --no-link --print-out-paths --impure --expr '({{ PAPER_EXPR }}).python3.withPackages (p: [p.pygobject3])')
    typelibs=$(nix build --no-link --print-out-paths --impure --expr 'let p = {{ PAPER_EXPR }}; in p.symlinkJoin { name = "paper-demo-typelibs"; paths = [p.gtk3 p.pango.out p.gdk-pixbuf p.atk p.harfbuzz p.glib.out p.gobject-introspection]; }')
    demo_cmd="env GI_TYPELIB_PATH=$typelibs/lib/girepository-1.0 GDK_BACKEND=wayland $py/bin/python3 $(realpath "$build/../tests/demo-window.py")"
    setsid dbus-run-session -- bash -c 'echo "$DBUS_SESSION_BUS_ADDRESS" > /tmp/paper-gala.bus; exec env GSETTINGS_BACKEND=memory GSETTINGS_SCHEMA_DIR=/tmp/paper-gala-schemas XDG_CURRENT_DESKTOP=Pantheon XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" "$@"' bash \
        "PAPER_DEMO_CMD=$demo_cmd" "$@" "$gala/bin/gala" --headless "${monitors[@]}" --wayland-display paper-0 --no-x11 \
        > /tmp/paper-gala.log 2>&1 < /dev/null &
    for _ in $(seq 40); do
        sleep 0.5
        grep -q "pantheon-paper: loaded" /tmp/paper-gala.log 2>/dev/null && { echo "running; log /tmp/paper-gala.log"; exit 0; }
    done
    echo "the plugin did not report loading; see /tmp/paper-gala.log" >&2
    exit 1

# Stop the headless Gala started by paper-run.
paper-stop:
    @pkill -f -- '--wayland-display[ ]paper-0' || true  # the [ ] keeps pkill from matching its own shell

# Capture the headless Gala's screen to OUT.
paper-shot out:
    @DBUS_SESSION_BUS_ADDRESS="$(cat /tmp/paper-gala.bus)" PANTHEON_SHOT_HEADLESS=1 just -f '{{ justfile_directory() }}/justfile' pantheon::shot '{{ out }}'

# Inject real input into the headless Gala (never the live session): see the
# plugin's tests/inject.py for the actions.
[no-cd]
[positional-arguments]
paper-inject *actions:
    #!/usr/bin/env bash
    set -euo pipefail
    py=$(nix build --no-link --print-out-paths --impure --expr '({{ PAPER_EXPR }}).python3.withPackages (p: [p.pygobject3])')
    glib=$(nix build --no-link --print-out-paths --impure --expr '({{ PAPER_EXPR }}).glib.out')
    DBUS_SESSION_BUS_ADDRESS="$(cat /tmp/paper-gala.bus)" GI_TYPELIB_PATH="$glib/lib/girepository-1.0" "$py/bin/python3" "${PAPER_INJECT:-tests/inject.py}" "$@"

# Fail if a pantheon-paper key clashes with another binding as HOST's built
# system resolves them (its dconf defaults, schema overrides, and Pantheon's
# desktop-specific values, which the plain session `gsettings` does not show
# unless XDG_CURRENT_DESKTOP=Pantheon). The user's own dconf values are left out.
paper-keys-check host="raider":
    #!/usr/bin/env bash
    set -euo pipefail
    top=$(nix build --no-link --print-out-paths '{{ justfile_directory() }}#nixosConfigurations.{{ host }}.config.system.build.toplevel')
    overrides=$(grep -o '/nix/store/[^"]*nixos-gsettings-overrides/glib-2.0/schemas' "$top/etc/set-environment" | head -n1)
    profile=$(grep -o 'DCONF_PROFILE="[^"]*"' "$top/etc/set-environment" | cut -d'"' -f2)
    # The system databases only: no user-db line, so the user's own values do not count.
    sysprofile=$(mktemp); grep -v '^user-db:' "$profile" > "$sysprofile"
    glib=$(nix build --no-link --print-out-paths --impure --expr '({{ PAPER_EXPR }}).glib.bin')
    env XDG_CURRENT_DESKTOP=Pantheon DCONF_PROFILE="$sysprofile" GSETTINGS_SCHEMA_DIR="$overrides" \
        "$glib/bin/gsettings" list-recursively | python3 '{{ justfile_directory() }}/scripts/pantheon-paper-keys.py'
