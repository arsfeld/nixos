# The dGPU's enforced power limit in the top bar: the number the
# nvidia-unclamp-tgp unit in nvidia.nix exists to change, and which has been
# seen reverting to 30 W mid-session. Printed for gnomeExtensions.executor,
# which runs it through `bash -c` on an interval.
#
# `nvidia-smi --query-gpu=power.limit` returns [N/A] on this GPU (measured on
# driver 595.71.05), so the limits have to come from the -q report, where they
# are populated. There "Current Power Limit" appears twice -- under GPU Power
# Readings and again under Module Power Readings, which is all N/A here -- so
# awk windows on the first block rather than grepping. P-state, memory clock
# and the SW Power Cap flag do work through --query-gpu.
#
# Called from both configuration.nix (systemPackages) and nvidia.nix (the
# Executor command); identical calls yield one derivation.
{
  writeShellScriptBin,
  nvidia,
}:
writeShellScriptBin "dgpu-power" ''
  smi=${nvidia.bin}/bin/nvidia-smi

  limits=$("$smi" -q -d POWER 2>/dev/null | awk '
    /GPU Power Readings/    { gpu = 1 }
    /Module Power Readings/ { gpu = 0 }
    gpu && /Current Power Limit/ { cur = $(NF - 1) }
    gpu && /Default Power Limit/ { print cur, $(NF - 1); exit }
  ')
  read -r cur def <<<"$limits"
  # Driver not loaded, or the fields read N/A: print nothing, not noise.
  case "$cur$def" in "" | *[!0-9.]*) exit 0 ;; esac

  IFS=, read -r pstate mem cap <<<"$(
    "$smi" --query-gpu=pstate,clocks.mem,clocks_event_reasons.sw_power_cap \
           --format=csv,noheader,nounits 2>/dev/null | tr -d ' '
  )"

  cap_flag=""
  [ "$cap" = Active ] && cap_flag=" cap"

  if [ "$cur" = "$def" ]; then
    printf '%.0fW %s %sMHz%s\n' "$cur" "$pstate" "$mem" "$cap_flag"
  else
    printf '! %.0f/%.0fW %s %sMHz%s\n' "$cur" "$def" "$pstate" "$mem" "$cap_flag"
  fi
''
