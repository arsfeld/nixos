# Constellation backup-status module
#
# One `backup-status` command per host, aggregating every backup orchestrator
# that host runs. galactica runs both rustic and backrest, so a script owned by
# either module alone would collide on the name; instead each module appends a
# source here and this module renders the aggregate.
#
# stdout is a JSON array, one object per repo/profile:
#   {name, kind, lastSnapshot, ageHours, maxAgeHours, ok, error}
#
# A source that cannot be queried reports ok:false with error set. It never
# aborts the run: a broken rclone repo must not hide a healthy local one.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.backupStatus;

  sourceType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Repo or profile name, unique within the host.";
      };
      kind = mkOption {
        type = types.enum ["rustic" "restic"];
        description = ''
          Which snapshot JSON shape `command` produces. rustic emits an array of
          {group_key, snapshots}; restic emits a flat array of snapshots.
        '';
      };
      command = mkOption {
        type = types.str;
        description = "Shell command printing snapshot JSON on stdout.";
      };
      maxAgeHours = mkOption {
        type = types.int;
        default = 48;
        description = ''
          Age above which this source reports ok:false. Must exceed the backup's
          own interval — galactica's weekly rustic profile needs 192, not the 48
          that suits a daily plan, or it reports stale every single week.
        '';
      };
    };
  };

  manifest = pkgs.writeText "backup-status-sources.json" (
    builtins.toJSON (map (s: {inherit (s) name kind command maxAgeHours;}) cfg.sources)
  );

  # Timestamps carry fractional seconds and a numeric offset
  # (2026-08-09T04:44:41.226088185-04:00). jq's fromdateiso8601 rejects that
  # form, and lexical sorting is wrong across differing offsets, so epoch
  # conversion goes through `date -d`.
  statusScript = pkgs.writeShellScriptBin "backup-status" ''
    set -uo pipefail
    export PATH=${makeBinPath [pkgs.jq pkgs.coreutils pkgs.gawk]}:$PATH

    now=$(date +%s)
    euid=$EUID
    out=""

    while IFS=$'\t' read -r name kind cmd maxage; do
      err="null"; last="null"; age="null"; ok="false"

      if raw=$(eval "$cmd" 2>/dev/null); then
        if [ "$kind" = "rustic" ]; then
          filter='[.[].snapshots[].time] | .[]'
        else
          filter='[.[].time] | .[]'
        fi

        if times=$(printf '%s' "$raw" | jq -r "$filter" 2>/dev/null); then
          best=0; bestiso=""
          for t in $times; do
            e=$(date -d "$t" +%s 2>/dev/null) || continue
            if [ "$e" -gt "$best" ]; then best=$e; bestiso=$t; fi
          done

          if [ "$best" -eq 0 ]; then
            err='"no snapshots"'
          else
            last="\"$bestiso\""
            age=$(awk -v n="$now" -v b="$best" 'BEGIN{printf "%.1f",(n-b)/3600}')
            ok=$(awk -v a="$age" -v m="$maxage" 'BEGIN{print (a<=m)?"true":"false"}')
          fi
        else
          err='"unparseable snapshot json"'
        fi
      else
        if [ "$euid" -eq 0 ]; then
          err='"query failed"'
        else
          err='"query failed (not root — rerun with sudo)"'
        fi
      fi

      out="$out$(jq -nc \
        --arg name "$name" --arg kind "$kind" \
        --argjson last "$last" --argjson age "$age" \
        --argjson max "$maxage" --argjson ok "$ok" --argjson err "$err" \
        '{name:$name,kind:$kind,lastSnapshot:$last,ageHours:$age,maxAgeHours:$max,ok:$ok,error:$err}')"
    done < <(jq -r '.[] | [.name,.kind,.command,.maxAgeHours] | @tsv' ${manifest})

    printf '%s' "$out" | jq -s '.'
  '';
in {
  options.constellation.backupStatus = {
    enable = mkEnableOption "aggregated backup freshness reporting";

    sources = mkOption {
      type = types.listOf sourceType;
      default = [];
      description = "Backup sources to query. Appended to by rustic.nix and backrest.nix.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [statusScript];
  };
}
