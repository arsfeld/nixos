#!/usr/bin/env bash
# Renders the avatar's Centurion head from its SVG source into the PNG the firmware embeds. The PNG is
# committed (the build does not run this); re-run it after editing ui/ui/images/centurion.svg.
set -euo pipefail
cd "$(dirname "$0")/../ui/ui/images"
nix run nixpkgs#resvg -- -w 280 -h 280 centurion.svg centurion-280.png
