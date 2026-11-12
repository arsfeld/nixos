#!/usr/bin/env bash
# Local patches to Slint 1.18.1, copied into vendor/ (gitignored) and wired in by [patch.crates-io] in Cargo.toml
# and app/Cargo.toml. Re-check both at every Slint bump.
#
# i-slint-core: Path support in no_std builds calls f32::rem_euclid, which only exists with std (and std pulls in
# memmap2, which does not build for ESP-IDF). The rest of the crate already uses num_traits::Euclid::rem_euclid for
# exactly this reason (see graphics/brush.rs).
#
# i-slint-renderer-software: Paths ignored the frame's dirty region and were blended over their whole clip, so with
# the board's reused framebuffer a Path next to anything animated repainted itself over the items drawn above it
# (the command menu's icons and labels vanished beside a pulsing session arc). patches/ has the fix.
set -euo pipefail
cd "$(dirname "$0")/.."

vendor() {
    local src
    src=$(ls -d "$HOME"/.cargo/registry/src/*/"$1"-1.18.1 | head -n1)
    rm -rf "vendor/$1"
    mkdir -p vendor
    cp -r "$src" "vendor/$1"
    chmod -R u+w "vendor/$1"
    echo "vendored $src"
}

vendor i-slint-core
sed -i 's|let mut rem = t.rem_euclid(1.);|let mut rem = num_traits::Euclid::rem_euclid(\&t, \&1.);|' vendor/i-slint-core/graphics/path.rs
grep -q 'Euclid::rem_euclid(&t, &1.)' vendor/i-slint-core/graphics/path.rs

vendor i-slint-renderer-software
patch -s -p1 -d vendor/i-slint-renderer-software < patches/i-slint-renderer-software-path-dirty-region.patch
