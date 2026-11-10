#!/usr/bin/env bash
# Local patch for i-slint-core 1.18.1: Path support in no_std builds calls f32::rem_euclid, which only
# exists with std (and std pulls in memmap2, which does not build for ESP-IDF). The rest of the crate
# already uses num_traits::Euclid::rem_euclid for exactly this reason (see graphics/brush.rs). The
# patched copy goes to vendor/ (gitignored) and Cargo.toml's [patch.crates-io] points at it.
set -euo pipefail
cd "$(dirname "$0")/.."
src=$(ls -d "$HOME"/.cargo/registry/src/*/i-slint-core-1.18.1 | head -n1)
rm -rf vendor/i-slint-core
mkdir -p vendor
cp -r "$src" vendor/i-slint-core
chmod -R u+w vendor/i-slint-core
sed -i 's|let mut rem = t.rem_euclid(1.);|let mut rem = num_traits::Euclid::rem_euclid(\&t, \&1.);|' vendor/i-slint-core/graphics/path.rs
grep -q 'Euclid::rem_euclid(&t, &1.)' vendor/i-slint-core/graphics/path.rs
echo "patched $src -> vendor/i-slint-core"
