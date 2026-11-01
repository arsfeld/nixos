#!/usr/bin/env bash
# Dendritic-restructure verification. Run from ~/Code/nixos.
#
#   verify.sh baseline [host...]   record the reference (once, before Task 1)
#   verify.sh check [host...]      compare the working tree against it
#
# Hosts are evaluated one at a time under nice: parallel toplevel evaluations
# have run raider out of memory. Per host, check prints
#   MATCH       strict fingerprint equal: nothing changed but the flake source
#   LOOSE-ONLY  equal only after token sorting: read `explain` before accepting
#   DIFF        a real change: explain and resolve before committing
# and the flake-output snapshot must match byte for byte. Exit status is 0 only
# when every host is MATCH and the snapshot matches; LOOSE-ONLY exits 2.
set -euo pipefail
D=/var/tmp/dendritic   # baselines and per-run data
HERE=$(cd "$(dirname "$0")" && pwd)
FP="python3 -I $HERE/fingerprint.py"
mode=${1:?usage: verify.sh baseline|check [host...]}
shift
out=$D/$mode
mkdir -p "$out"

snapshot() {
  {
    for a in hosts tiers unstableHosts ciExcludedHosts ciMatrix; do
      printf '%s ' "$a"
      nix eval --json ".#$a"
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
  drv=$(nice nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath")
  echo "$drv" >"$out/$h.drv"
  nix derivation show -r "$drv" | zstd -q -f -o "$out/$h.json.zst"
  zstd -dc "$out/$h.json.zst" | $FP hash "$drv" >"$out/$h.fp"
  zstd -dc "$out/$h.json.zst" | $FP hash --loose "$drv" >"$out/$h.loose"
  if [ "$mode" = check ]; then
    b=$D/baseline
    if cmp -s "$b/$h.fp" "$out/$h.fp"; then
      echo "MATCH       $h"
    elif cmp -s "$b/$h.loose" "$out/$h.loose"; then
      echo "LOOSE-ONLY  $h   ($FP explain $b/$h.json.zst $(cat "$b/$h.drv") $out/$h.json.zst $drv)"
      [ $status -eq 0 ] && status=2
    else
      echo "DIFF        $h   ($FP explain $b/$h.json.zst $(cat "$b/$h.drv") $out/$h.json.zst $drv)"
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
fi
exit $status
