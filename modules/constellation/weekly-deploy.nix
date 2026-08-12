# Constellation weekly-deploy module
#
# galactica pulls master and deploys tier-1 once a week, then reports. It must
# never build: NIX_CONFIG="max-jobs = 0" makes local compilation impossible, so
# a closure missing from attic is a loud error instead of a compile that OOMs
# the host running the media stack.
#
# The contract with CI: a fresh flake.lock on master means tier-1 built clean,
# because update.yml gates its commit on exactly those three hosts. This module
# therefore never has to reason about CI status for correctness — only to avoid
# racing a commit whose closures are still uploading.
#
# flake.lock's age is also reported and treated as a health signal in its own
# right. update.yml's own ntfy notify step cannot fire on failure: Cloudflare
# serves GitHub-hosted runners a managed challenge (HTTP 403) on
# ntfy.arsfeld.one, so CI can never post there. A flake.lock that hasn't moved
# in two-plus weeks is the only observable trace of that failure, and galactica
# — unlike a GitHub runner — can actually reach ntfy, so it closes the loop.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
with lib; let
  cfg = config.constellation.weeklyDeploy;

  deployScript = pkgs.writeShellScriptBin "weekly-deploy" ''
    set -uo pipefail
    export PATH=${makeBinPath [
      pkgs.git
      pkgs.colmena
      pkgs.openssh
      pkgs.jq
      pkgs.curl
      pkgs.nix
      pkgs.coreutils
      pkgs.gnused
    ]}:$PATH

    STATE=${cfg.stateDir}
    REPO="$STATE/nixos"
    HOSTS="${concatStringsSep " " cfg.hosts}"
    LOCK_STALE_DAYS=14

    notify() {
      ${config.constellation.backupNotify.script} "$1" "$2" || true
    }

    mkdir -p "$STATE"

    if [ ! -d "$REPO/.git" ]; then
      git clone ${escapeShellArg cfg.repoUrl} "$REPO" || {
        notify "Weekly deploy failed on ${config.networking.hostName}" "git clone failed"
        exit 1
      }
    fi

    cd "$REPO"
    git fetch --prune origin || {
      notify "Weekly deploy failed on ${config.networking.hostName}" "git fetch failed"
      exit 1
    }
    git reset --hard origin/master
    SHA=$(git rev-parse HEAD)

    # flake.lock's last-commit time doubles as a health check on update.yml
    # itself (see module header): a lock CI hasn't touched in two missed
    # Sundays means the automation broke silently, and nothing else here would
    # ever surface that.
    LOCK_COMMIT_ISO=$(git log -1 --format=%cI -- flake.lock 2>/dev/null || echo "")
    LOCK_EPOCH=""
    [ -n "$LOCK_COMMIT_ISO" ] && LOCK_EPOCH=$(date -d "$LOCK_COMMIT_ISO" +%s 2>/dev/null || echo "")
    if [ -n "$LOCK_EPOCH" ]; then
      LOCK_AGE_DAYS=$(( ($(date +%s) - LOCK_EPOCH) / 86400 ))
    else
      LOCK_AGE_DAYS=-1
    fi

    LOCK_STALE=0
    if [ "$LOCK_AGE_DAYS" -ge 0 ] && [ "$LOCK_AGE_DAYS" -gt "$LOCK_STALE_DAYS" ]; then
      LOCK_STALE=1
    fi

    if [ "$LOCK_AGE_DAYS" -ge 0 ]; then
      LOCK_LINE="flake.lock: ''${LOCK_AGE_DAYS}d old (committed $LOCK_COMMIT_ISO)"
      [ "$LOCK_STALE" -eq 1 ] && LOCK_LINE="$LOCK_LINE - STALE, CI may not be landing updates"
    else
      LOCK_LINE="flake.lock: age unknown (no commit history found)"
    fi

    # Precondition: only deploy a commit CI has finished building and pushing.
    # Without this, a commit whose closures are still uploading fails every node
    # on max-jobs=0 and reads as a fleet outage rather than a timing artifact.
    CONCL=$(curl -sS --max-time 30 \
      "https://api.github.com/repos/${cfg.repoSlug}/actions/runs?head_sha=$SHA&per_page=20" \
      | jq -r '[.workflow_runs[] | select(.name=="Build & Cache")]
               | sort_by(.created_at) | last | .conclusion // "none"' 2>/dev/null || echo "none")

    if [ "$CONCL" != "success" ]; then
      SKIP_BODY="master $SHA is not green (Build & Cache: $CONCL). Nothing was deployed."$'\n'"$LOCK_LINE"
      notify "Weekly deploy skipped on ${config.networking.hostName}" "$SKIP_BODY"
      exit 0
    fi

    # Reachability probe that doubles as known_hosts seeding: colmena's ssh
    # would otherwise fail on an unknown host key. Tailscale is the trust
    # boundary here — these hosts are already tailnet-authenticated.
    for h in $HOSTS; do
      ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
        "root@$h.bat-boa.ts.net" true 2>/dev/null || true
    done

    export NIX_CONFIG="max-jobs = 0"
    colmena apply ${optionalString cfg.impureEval "--impure "}--on @tier1 \
      >"$STATE/last-deploy.log" 2>&1 || true

    for h in $HOSTS; do
      ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$h.bat-boa.ts.net" \
        systemctl start multi-user.target 2>/dev/null || true
    done

    RESULTS=""
    HOST_PROBLEMS=0
    SUMMARY="$LOCK_LINE"$'\n'

    for h in $HOSTS; do
      TARGET="root@$h.bat-boa.ts.net"
      GEN=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" \
        'readlink -f /run/current-system' 2>/dev/null || echo "unreachable")
      FAILED=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" \
        'systemctl --failed --no-legend | awk "{print \$1}" | paste -sd, -' 2>/dev/null || echo "?")
      BACKUPS=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" \
        'backup-status' 2>/dev/null || echo "[]")

      STALE=$(printf '%s' "$BACKUPS" \
        | jq -r '[.[] | select(.ok | not) | .name] | join(",")' 2>/dev/null || echo "?")

      HOST_BAD=0
      [ "$GEN" = "unreachable" ] && HOST_BAD=1
      [ -n "$FAILED" ] && [ "$FAILED" != "?" ] && HOST_BAD=1
      [ -n "$STALE" ] && [ "$STALE" != "?" ] && HOST_BAD=1
      [ "$HOST_BAD" -eq 1 ] && HOST_PROBLEMS=$((HOST_PROBLEMS + 1))

      if [ "$HOST_BAD" -eq 1 ]; then
        SUMMARY="$SUMMARY$h: FAILED=[''${FAILED:-none}] STALE=[''${STALE:-none}] GEN=$GEN"$'\n'
      else
        SUMMARY="$SUMMARY$h: ok"$'\n'
      fi

      RESULTS="$RESULTS$(jq -nc \
        --arg host "$h" --arg gen "$GEN" --arg failed "$FAILED" --arg stale "$STALE" \
        --argjson backups "$(printf '%s' "$BACKUPS" | jq -c . 2>/dev/null || echo '[]')" \
        '{host:$host,generation:$gen,failedUnits:$failed,staleBackups:$stale,backups:$backups}')"
    done

    printf '%s' "$RESULTS" | jq -s \
      --arg sha "$SHA" --arg when "$(date -Is)" \
      --argjson lockAgeDays "$LOCK_AGE_DAYS" --arg lockCommitTime "$LOCK_COMMIT_ISO" \
      '{commit:$sha,ranAt:$when,lockAgeDays:$lockAgeDays,lockCommitTime:$lockCommitTime,hosts:.}' > "$STATE/last-run.json"

    TOTAL=$(printf '%s' "$HOSTS" | wc -w)
    OK=$((TOTAL - HOST_PROBLEMS))
    PROBLEMS=$((HOST_PROBLEMS + LOCK_STALE))

    if [ "$PROBLEMS" -gt 0 ]; then
      notify "ACTION NEEDED - weekly deploy: $OK/$TOTAL healthy" "$SUMMARY"
    else
      notify "Weekly deploy: $OK/$TOTAL healthy" "$SUMMARY"
    fi

    exit 0
  '';
in {
  options.constellation.weeklyDeploy = {
    enable = mkEnableOption "weekly tier-1 update, deploy and health report";

    hosts = mkOption {
      type = types.listOf types.str;
      default = self.tiers.tier1;
      description = ''
        Hosts included in the verification sweep. Derived from the same tier
        definition the deploy targets (@tier1), so the sweep cannot drift out of
        sync with what was actually deployed.
      '';
    };

    schedule = mkOption {
      type = types.str;
      default = "Sun *-*-* 06:00:00 UTC";
      description = "OnCalendar spec. Must land after the Sunday 00:00 UTC CI run.";
    };

    repoUrl = mkOption {
      type = types.str;
      default = "https://github.com/arsfeld/nixos.git";
      description = "Public clone URL. https so the unit needs no credentials.";
    };

    repoSlug = mkOption {
      type = types.str;
      default = "arsfeld/nixos";
      description = "owner/repo, used for the GitHub Actions status query.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/weekly-deploy";
      description = "Machine-owned checkout, logs and last-run.json. Holds no user data.";
    };

    impureEval = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Pass --impure to colmena, matching `just deploy`. Set false if the
        pre-flight check showed impure evaluation yields different derivations
        than CI built, which would break substitution-only deploys.
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.services.weekly-deploy = {
      description = "Weekly tier-1 update, deploy and health report";
      after = ["network-online.target" "tailscaled.service"];
      wants = ["network-online.target"];

      # This unit deploys the host it runs on. Without these, activation
      # restarts the job mid-flight and the report never gets sent.
      restartIfChanged = false;
      stopIfChanged = false;

      onFailure = ["backup-notify@weekly-deploy.service"];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${deployScript}/bin/weekly-deploy";
        EnvironmentFile = config.constellation.backupNotify.envFile;
        # A runaway evaluation dies in its own cgroup instead of taking the
        # media stack down with it.
        MemoryMax = "12G";
        Nice = 10;
        TimeoutStartSec = "3h";
      };
    };

    systemd.timers.weekly-deploy = {
      description = "Timer for weekly-deploy";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = 600;
      };
    };

    systemd.tmpfiles.rules = ["d ${cfg.stateDir} 0700 root root -"];
  };
}
