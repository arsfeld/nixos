# Pull recorded clips off the HomeBase's local storage.
#
# Home Assistant's eufy integration can't do this, and neither can eufy's web
# portal: both only ever see cloud-backed events, while most of this fleet's
# footage sits on the HomeBase 3. See just/eufy-clip.mjs for the protocol
# details — the whole thing is a thin wrapper around an archived client, and
# every sharp edge is documented in that file's header.
#
# The work happens on galactica, which is the host with LAN P2P reach to the
# stations and the sops secret holding the account. These recipes copy the
# script over and run it there, so no deploy is needed to change it.
#
# ONE SESSION PER ACCOUNT. The secondary eufy account is held by
# eufy-sdk-bridge (hosts/galactica/services/eufy.nix), so `up` stops that
# bridge and `down` restarts it. Home Assistant's eufy cameras, sensors and
# doorbell events are all dead in between — always `down` when finished. The
# permanent fix is a third eufy account shared into the home, which would let
# both run at once; until then, keep the window short.

HOST := "galactica.bat-boa.ts.net"
REMOTE := "/tmp/eufy-clip.mjs"

# Copy the current script to galactica. Every recipe below routes through this,
# so an edit here takes effect on the next run with no deploy.
_sync:
    @scp -q '{{ justfile_directory() }}/just/eufy-clip.mjs' '{{ HOST }}:{{ REMOTE }}'

# Login is persisted in /var/data/eufy-clip-ws, so 2FA is normally asked only on
# the very first run.

# Stop the HA bridge and start the ws server.
up: _sync
    @ssh '{{ HOST }}' node '{{ REMOTE }}' up

# Stop the ws server and restart the HA bridge. Run this when you're done.
down: _sync
    @ssh '{{ HOST }}' node '{{ REMOTE }}' down

# Submit an emailed 2FA code, if `up` asked for one.
code CODE: _sync
    @ssh '{{ HOST }}' node '{{ REMOTE }}' code '{{ CODE }}'

# Worth a look when a download misbehaves: a camera listed as its own station
# keeps its recordings on the HomeBase anyway, which is the case the script
# routes around.

# Stations and devices, with the station each device reports to.
stations: _sync
    @ssh '{{ HOST }}' node '{{ REMOTE }}' stations

# What's on local storage. `just eufy::list 20260918`, or a range.
list *ARGS: _sync
    @ssh '{{ HOST }}' node '{{ REMOTE }}' list {{ ARGS }}

#   just eufy::grab 20260918 --device="Kids Room" --from=14:00 --to=18:00
#   just eufy::grab 20260918 --device=Doorbell --dry-run
# Lands in /var/tmp/eufy-clips/<day> on galactica unless --out= says otherwise.
# Run it with --dry-run first: a busy camera can be a hundred clips.

# Download everything matching a day, optionally a camera and a time window.
grab *ARGS: _sync
    @ssh '{{ HOST }}' node '{{ REMOTE }}' grab {{ ARGS }}

# One clip by record id: `just eufy::get 2026091801325 20260918 out.mp4`.
get *ARGS: _sync
    @ssh '{{ HOST }}' node '{{ REMOTE }}' get {{ ARGS }}

#   just eufy::fetch 20260918

# Copy downloaded clips back from galactica into ./eufy-clips (gitignored).
fetch DAY DEST=(justfile_directory() / "eufy-clips"):
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p '{{ DEST }}/{{ DAY }}'
    scp -q '{{ HOST }}:/var/tmp/eufy-clips/{{ DAY }}/*.mp4' '{{ DEST }}/{{ DAY }}/'
    echo "fetched into {{ DEST }}/{{ DAY }}"
    du -sh '{{ DEST }}/{{ DAY }}'
