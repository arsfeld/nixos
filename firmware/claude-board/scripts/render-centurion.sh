#!/usr/bin/env bash
# Renders the avatar's Centurion head from its SVG source into the PNGs the firmware embeds (280 px for the
# avatar, 180 px for the purge page's small head, each drawn at its native size). The PNGs are
# committed (the build does not run this); re-run it after editing ui/ui/images/centurion.svg.
set -euo pipefail
cd "$(dirname "$0")/../ui/ui/images"
nix run nixpkgs#resvg -- -w 280 -h 280 centurion.svg centurion-280.png
nix run nixpkgs#resvg -- -w 180 -h 180 centurion.svg centurion-180.png
