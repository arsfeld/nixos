# Constellation weekly-deploy module
#
# galactica pulls master and deploys tier-1 once a week, then reports. It must
# never build: NIX_CONFIG="max-jobs = 0" makes local compilation impossible, so
# a closure missing from attic is a loud error instead of a compile that OOMs
# the host running the media stack.
#
# The contract with CI: a fresh flake.lock on master means tier-1 built clean,
# because update.yml gates its commit on exactly those three hosts. This module
# still re-checks CI before deploying — not to re-derive that guarantee, but to
# avoid racing a commit whose closures are still uploading. That check is scoped
# to the tier-1 build jobs specifically (see the precondition below), not the
# whole "Build & Cache" run's conclusion: the run that fires for master's new
# HEAD rebuilds all nine hosts, and an unrelated octopi/blackbird/router
# failure must not block a tier-1 deploy that already provably built.
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

  # Tailscale SSH cannot authenticate a host connecting to itself (see
  # flake-modules/colmena.nix's allowLocalDeployment comment), so the local
  # host must be applied via `colmena apply-local`, never over `--on`.
  # Computed from config.networking.hostName at Nix eval time rather than a
  # runtime `hostname` call, so this can never disagree with which colmena
  # node this machine actually is.
  localHost = config.networking.hostName;
  remoteHosts = filter (h: h != localHost) cfg.hosts;
  localIncluded = elem localHost cfg.hosts;

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
      # The verification sweep parses `systemctl --failed` output with awk.
      # Nothing puts awk on a systemd unit's PATH by default (the per-unit
      # default is coreutils/findutils/gnugrep/gnused/systemd), so without
      # this the parse silently produced nothing.
      pkgs.gawk
    ]}:$PATH

    STATE=${cfg.stateDir}
    REPO="$STATE/nixos"
    HOSTS="${concatStringsSep " " cfg.hosts}"
    LOCK_STALE_DAYS=14

    notify() {
      ${config.constellation.backupNotify.script} "$1" "$2" || true
    }

    LOCAL_HOST="${localHost}"

    # Runs a command on host $1: locally when $1 is this host (Tailscale SSH
    # cannot authenticate a host to itself — same reason `colmena apply-local`
    # is used above), over ssh otherwise. $2 is a single command string, and
    # both branches hand it to exactly one shell for parsing (bash -c
    # locally, the remote user's shell via ssh) — a command written once
    # therefore behaves identically either way.
    #
    # The two branches must also see the same *tools*, which is not automatic.
    # The ssh branch lands in a login environment that already has the target's
    # system profile on PATH; the local branch inherits only this unit's PATH,
    # which is the script's own closure plus systemd's per-unit default — and
    # that has no /run/current-system/sw/bin on it at all. Host-provided
    # commands the sweep depends on (notably `backup-status`, generated
    # per-host by constellation.backupStatus) would resolve remotely and fail
    # locally, and a failed lookup here reads as "nothing wrong". Prepending
    # the running system profile gives the local branch the same surface,
    # resolved live rather than pinned to a store path, exactly as the remote
    # branch resolves it.
    #
    # HOME is part of that surface too. systemd sets no HOME for a root system
    # service (it does set USER, LANG, PWD and PATH — checked, HOME is the only
    # one missing), while an ssh login gets HOME=/root. restic needs it to site
    # its cache: 0.18 only warns, but 0.19 treats an undeterminable cache dir as
    # fatal and exits non-zero, which would report every restic repo on this
    # host as stale while the backups are fine. Since this unit deploys the very
    # host it runs on, it would ship that restic bump to itself and then start
    # lying about its own backups. Scoped to this one invocation rather than set
    # unit-wide, so git/nix/colmena keep running without root's dotfiles exactly
    # as they do today.
    run_on() {
      local host="$1" cmd="$2"
      if [ "$host" = "$LOCAL_HOST" ]; then
        HOME=/root PATH="/run/current-system/sw/bin:$PATH" ${pkgs.bash}/bin/bash -c "$cmd"
      else
        ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$host.bat-boa.ts.net" "$cmd"
      fi
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

    # Precondition: only deploy once every tier-1 host's own build job
    # succeeded in this SHA's latest "Build & Cache" run — not once the
    # whole run is green. A commit landing on master always triggers a
    # fresh, full-fleet "Build & Cache" run (job names are bare "<host>"
    # for all nine hosts); update.yml's own workflow_call invocation
    # nests its jobs as "build / <host>" and only ever covers tier-1.
    # Gating on the run's overall conclusion would let an unrelated
    # octopi/blackbird/router failure block every tier-1 deploy — the
    # same failure mode Task 2 removed from the commit gate, reintroduced
    # one layer down. Match jobs by their trailing "/"-delimited token so
    # both naming schemes resolve to the same host name; a tier-1 host
    # with no matching job at all counts as not-green, not as a pass.
    RUN_ID=$(curl -sS --max-time 30 \
      "https://api.github.com/repos/${cfg.repoSlug}/actions/runs?head_sha=$SHA&per_page=20" \
      | jq -r '[.workflow_runs[] | select(.name=="Build & Cache")]
               | sort_by(.created_at) | last | .id // empty' 2>/dev/null || echo "")

    JOBS_JSON=""
    if [ -n "$RUN_ID" ]; then
      JOBS_JSON=$(curl -sS --max-time 30 \
        "https://api.github.com/repos/${cfg.repoSlug}/actions/runs/$RUN_ID/jobs?per_page=100" \
        2>/dev/null || echo "")
    fi

    BAD=""
    if [ -z "$RUN_ID" ]; then
      BAD="no Build & Cache run found for $SHA"
    else
      for h in $HOSTS; do
        JSTATUS=$(printf '%s' "$JOBS_JSON" | jq -r --arg host "$h" '
          ([.jobs[]? | select((.name | split("/") | last | gsub("^[ \t]+|[ \t]+$";"")) == $host)]) as $m
          | if ($m | length) == 0 then "missing"
            elif ($m | any(.conclusion == "success")) then "success"
            else ($m | map(.conclusion) | join(","))
            end
        ' 2>/dev/null || echo "error")
        [ "$JSTATUS" != "success" ] && BAD="$BAD$h:$JSTATUS "
      done
    fi

    if [ -n "$BAD" ]; then
      SKIP_BODY="master $SHA is not green for tier-1 (''${BAD% }). Nothing was deployed."$'\n'"$LOCK_LINE"
      notify "Weekly deploy skipped on ${config.networking.hostName}" "$SKIP_BODY"
      exit 0
    fi

    # Reachability probe that doubles as known_hosts seeding: colmena's ssh
    # would otherwise fail on an unknown host key. Tailscale is the trust
    # boundary here — these hosts are already tailnet-authenticated. Skips
    # the local host: there is no remote host key to seed for a loopback
    # connection, and Tailscale SSH cannot authenticate self-connections
    # anyway, so attempting it would only add meaningless noise to the
    # journal.
    for h in $HOSTS; do
      [ "$h" = "$LOCAL_HOST" ] && continue
      ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
        "root@$h.bat-boa.ts.net" true 2>/dev/null || true
    done

    export NIX_CONFIG="max-jobs = 0"
    : > "$STATE/last-deploy.log"

    # Two invocations, not one `--on @tier1`: colmena would SSH to the local
    # host too under `--on`, and that SSH always fails (see module header /
    # flake-modules/colmena.nix). Remote hosts still go through `apply`;
    # ${localHost} goes through `apply-local`, which runs in-process as this
    # unit's own root, no SSH involved. Either invocation is best-effort so one
    # failing never blocks the other, the verification sweep, or the summary —
    # but its exit status is captured rather than thrown away with `|| true`.
    # A deploy that failed everywhere leaves every host answering readlink,
    # systemctl and backup-status perfectly well from its OLD generation, so
    # without this the run announces "3/3 healthy" and the operator reads that
    # as "this week's update landed" when nothing was deployed at all. An empty
    # --on list means "all nodes" to colmena, so the remote invocation is only
    # ever emitted when there's at least one remote host to deploy.
    DEPLOY_REMOTE_RC=0
    DEPLOY_LOCAL_RC=0
    ${optionalString (remoteHosts != []) ''
      colmena apply ${optionalString cfg.impureEval "--impure "}--on ${escapeShellArg (concatStringsSep "," remoteHosts)} \
        >>"$STATE/last-deploy.log" 2>&1 || DEPLOY_REMOTE_RC=$?
    ''}
    ${optionalString localIncluded ''
      colmena apply-local ${optionalString cfg.impureEval "--impure "}--node ${escapeShellArg localHost} \
        >>"$STATE/last-deploy.log" 2>&1 || DEPLOY_LOCAL_RC=$?
    ''}

    for h in $HOSTS; do
      run_on "$h" "systemctl start multi-user.target" 2>/dev/null || true
    done

    RESULTS=""
    HOST_PROBLEMS=0

    # Deploy outcome leads the body next to the lock line, so "did this week's
    # update actually land" is answerable without reading the per-host lines.
    if [ "$DEPLOY_REMOTE_RC" -ne 0 ] || [ "$DEPLOY_LOCAL_RC" -ne 0 ]; then
      DEPLOY_LINE="deploy FAILED: colmena apply rc=$DEPLOY_REMOTE_RC, apply-local rc=$DEPLOY_LOCAL_RC (see $STATE/last-deploy.log)"
    else
      DEPLOY_LINE="deploy: ok"
    fi

    SUMMARY="$LOCK_LINE"$'\n'"$DEPLOY_LINE"$'\n'

    # Every check has three outcomes, not two: it ran and found nothing wrong,
    # it ran and found a problem, or it could not run at all. Folding the third
    # into the first is how this sweep reported a host healthy while it was
    # broken — an unresolvable `backup-status` fell into `|| echo "[]"`, and an
    # empty array has no stale entries. A check that did not run is therefore
    # collected in CHECK_ERRS and marks the host bad, same as unreachable;
    # "unknown" is never rounded down to "fine".
    for h in $HOSTS; do
      HOST_BAD=0
      CHECK_ERRS=""

      # Which invocation covered this host: every host in $HOSTS is either the
      # local one or one of the remote ones, which is exactly the split the two
      # colmena calls follow.
      if [ "$h" = "$LOCAL_HOST" ]; then
        DEPLOY_RC=$DEPLOY_LOCAL_RC
      else
        DEPLOY_RC=$DEPLOY_REMOTE_RC
      fi

      GEN=$(run_on "$h" "readlink -f /run/current-system" 2>/dev/null) || {
        GEN="unreachable"
        CHECK_ERRS="$CHECK_ERRS generation"
      }

      # Collect raw remotely, parse here. A pipeline exits with its *last*
      # stage's status, so the previous `systemctl | awk | paste` exited 0 even
      # when awk was missing entirely, handing back empty output that read as
      # "no failed units". One command per remote call keeps its exit status
      # meaningful, and the parse then runs under this script's own pipefail
      # with this script's own awk. --plain drops the "●" marker systemd
      # prefixes to each failed unit, which is otherwise the only thing
      # `{print $1}` ever sees.
      if FAILED_RAW=$(run_on "$h" "systemctl list-units --state=failed --no-legend --plain" 2>/dev/null); then
        FAILED=$(printf '%s\n' "$FAILED_RAW" | awk 'NF {print $1}' | paste -sd, -) || {
          FAILED="?"
          CHECK_ERRS="$CHECK_ERRS failed-units-parse"
        }
      else
        FAILED="?"
        CHECK_ERRS="$CHECK_ERRS failed-units"
      fi

      # Three ways this check fails to produce an answer, and none of them may
      # look like a clean bill of health. Empty stdout is the subtle one: jq
      # reads no input, emits nothing and exits 0, so STALE would come back
      # empty — indistinguishable from "no stale repos" — and the empty string
      # would additionally blow up --argjson below and drop this host from
      # last-run.json entirely.
      if ! BACKUPS=$(run_on "$h" "backup-status" 2>/dev/null); then
        BACKUPS="[]"
        STALE="?"
        CHECK_ERRS="$CHECK_ERRS backup-status"
      elif [ -z "$BACKUPS" ]; then
        BACKUPS="[]"
        STALE="?"
        CHECK_ERRS="$CHECK_ERRS backup-status-empty"
      else
        STALE=$(printf '%s' "$BACKUPS" \
          | jq -r '[.[] | select(.ok | not) | .name] | join(",")' 2>/dev/null) || {
          STALE="?"
          BACKUPS="[]"
          CHECK_ERRS="$CHECK_ERRS backup-status-unparseable"
        }
      fi

      CHECK_ERRS="''${CHECK_ERRS# }"

      [ "$DEPLOY_RC" -ne 0 ] && HOST_BAD=1
      [ "$GEN" = "unreachable" ] && HOST_BAD=1
      [ -n "$FAILED" ] && [ "$FAILED" != "?" ] && HOST_BAD=1
      [ -n "$STALE" ] && [ "$STALE" != "?" ] && HOST_BAD=1
      [ -n "$CHECK_ERRS" ] && HOST_BAD=1
      [ "$HOST_BAD" -eq 1 ] && HOST_PROBLEMS=$((HOST_PROBLEMS + 1))

      if [ "$HOST_BAD" -eq 1 ]; then
        LINE="$h:"
        # A failed deploy on a host that still answers every check is a
        # different situation from a host that fell off the network, and the
        # operator has to be able to tell them apart at a glance.
        if [ "$DEPLOY_RC" -ne 0 ]; then
          if [ "$GEN" = "unreachable" ]; then
            LINE="$LINE DEPLOY-FAILED(rc=$DEPLOY_RC, host unreachable)"
          else
            LINE="$LINE DEPLOY-FAILED(rc=$DEPLOY_RC, host up - still on its previous generation)"
          fi
        fi
        LINE="$LINE FAILED=[''${FAILED:-none}] STALE=[''${STALE:-none}] GEN=$GEN"
        [ -n "$CHECK_ERRS" ] && LINE="$LINE CHECKS-DID-NOT-RUN=[$CHECK_ERRS]"
        SUMMARY="$SUMMARY$LINE"$'\n'
      else
        SUMMARY="$SUMMARY$h: ok"$'\n'
      fi

      RESULTS="$RESULTS$(jq -nc \
        --arg host "$h" --arg gen "$GEN" --arg failed "$FAILED" --arg stale "$STALE" \
        --arg checkErrors "$CHECK_ERRS" --argjson deployRc "$DEPLOY_RC" \
        --argjson backups "$(printf '%s' "$BACKUPS" | jq -c . 2>/dev/null || echo '[]')" \
        '{host:$host,generation:$gen,deployRc:$deployRc,failedUnits:$failed,staleBackups:$stale,checkErrors:$checkErrors,backups:$backups}')"
    done

    printf '%s' "$RESULTS" | jq -s \
      --arg sha "$SHA" --arg when "$(date -Is)" \
      --argjson lockAgeDays "$LOCK_AGE_DAYS" --arg lockCommitTime "$LOCK_COMMIT_ISO" \
      --argjson deployRemoteRc "$DEPLOY_REMOTE_RC" --argjson deployLocalRc "$DEPLOY_LOCAL_RC" \
      '{commit:$sha,ranAt:$when,lockAgeDays:$lockAgeDays,lockCommitTime:$lockCommitTime,deployRemoteRc:$deployRemoteRc,deployLocalRc:$deployLocalRc,hosts:.}' > "$STATE/last-run.json"

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
