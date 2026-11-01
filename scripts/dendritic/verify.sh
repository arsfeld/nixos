#!/usr/bin/env bash
# Dendritic-restructure verification. Run from ~/Code/nixos.
#
#   verify.sh baseline [host...]   record the reference (once, before Task 1)
#   verify.sh check [host...]      compare the working tree against it
#
# Hosts are evaluated one at a time under nice: parallel toplevel evaluations
# have run raider out of memory. Per host, check prints
#   MATCH       strict fingerprint equal: nothing changed but the flake source
#   LOOSE-ONLY  equal only after sorting: read the printed command before accepting
#   DIFF        a real change: explain and resolve before committing
# then whether the flake-output snapshot matches byte for byte, and whether every
# flake check still evaluates. Exit status is 0 only when everything is MATCH/OK;
# LOOSE-ONLY alone exits 2.
#
# cylon-link is never built and its toplevel is never evaluated: evaluating it
# builds its armv7l cross toolchain (import-from-derivation). It is compared on
# a dump of evaluated settings instead (cylon-link-settings.nix), with
# import-from-derivation disabled so nothing can start building, and store
# hashes normalized away. Weaker than a fingerprint: it sees units, /etc text,
# users, packages and firewall settings, not derivation contents. The
# cylon-link-config check is skipped for the same reason; never run
# `nix flake check`, which evaluates both.
set -euo pipefail
D=/var/tmp/dendritic # baselines and per-run data
HERE=$(cd "$(dirname "$0")" && pwd)
FP="python3 -I $HERE/fingerprint.py"
NO_IFD=(--option allow-import-from-derivation false)
SETTINGS_ONLY=" cylon-link "
SKIP_CHECKS='["cylon-link-config"]'
mode=${1:?usage: verify.sh baseline|check [host...]}
shift
out=$D/$mode
mkdir -p "$out"

snapshot() {
  {
    for a in hosts tiers unstableHosts ciExcludedHosts ciMatrix; do
      printf '%s ' "$a"
      nix eval --json "${NO_IFD[@]}" ".#$a"
      echo
    done
    printf 'lightHosts '
    { nix eval --json .#lightHosts 2>/dev/null || nix eval --json .#lib.lightHosts; } | jq -c sort
    printf 'deployTargets '
    nix eval --json .#deployTargets --apply builtins.attrNames
    echo
  } >"$1"
}

hosts=("$@")
if [ ${#hosts[@]} -eq 0 ]; then
  mapfile -t hosts < <(nix eval --json .#hosts | jq -r '.[]')
fi

snapshot "$out/outputs.txt"
status=0
for h in "${hosts[@]}"; do
  b=$D/baseline
  if [[ "$SETTINGS_ONLY" == *" $h "* ]]; then
    nice nix eval --json "${NO_IFD[@]}" ".#nixosConfigurations.$h" --apply "$(cat "$HERE/cylon-link-settings.nix")" |
      sed -E 's|/nix/store/[0-9a-z]{32}-|/nix/store/HASH-|g' >"$out/$h.settings.json"
    jq -S . "$out/$h.settings.json" | sha256sum >"$out/$h.fp"
    jq -S 'walk(if type == "array" then sort else . end)' "$out/$h.settings.json" | sha256sum >"$out/$h.loose"
    how="diff <(jq -S . $b/$h.settings.json) <(jq -S . $out/$h.settings.json)"
  else
    drv=$(nice nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath")
    echo "$drv" >"$out/$h.drv"
    nix derivation show -r "$drv" | zstd -q -f -o "$out/$h.json.zst"
    zstd -dc "$out/$h.json.zst" | $FP hash "$drv" >"$out/$h.fp"
    zstd -dc "$out/$h.json.zst" | $FP hash --loose "$drv" >"$out/$h.loose"
    how="$FP explain $b/$h.json.zst \$(cat $b/$h.drv) $out/$h.json.zst $drv"
  fi
  if [ "$mode" = check ]; then
    if cmp -s "$b/$h.fp" "$out/$h.fp"; then
      echo "MATCH       $h"
    elif cmp -s "$b/$h.loose" "$out/$h.loose"; then
      echo "LOOSE-ONLY  $h   ($how)"
      [ $status -eq 0 ] && status=2
    else
      echo "DIFF        $h   ($how)"
      status=1
    fi
  else
    echo "recorded    $h"
  fi
done

if [ "$mode" = check ]; then
  if diff -u "$D/baseline/outputs.txt" "$out/outputs.txt"; then
    echo "MATCH       flake outputs"
  else
    echo "DIFF        flake outputs"
    status=1
  fi
  # Every check still evaluates (they are built in CI, by checks.yml).
  if nice nix eval --json "${NO_IFD[@]}" .#checks.x86_64-linux \
    --apply "cs: builtins.mapAttrs (_: c: c.drvPath) (removeAttrs cs (builtins.fromJSON ''$SKIP_CHECKS''))" >"$out/checks.json"; then
    echo "OK          flake checks evaluate ($(jq length "$out/checks.json"); skipped $SKIP_CHECKS)"
  else
    echo "FAIL        flake checks"
    status=1
  fi
fi
exit $status
