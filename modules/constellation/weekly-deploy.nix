# Constellation weekly-deploy module
#
# galactica pulls master and deploys tier-1 once a week, then reports. It must
# never build: NIX_CONFIG="max-jobs = 0" makes local compilation impossible, so
# a closure missing from the cache is a loud error instead of a compile that OOMs
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

  # Tailscale SSH cannot authenticate a host connecting to itself (the loopback
  # connection bypasses Tailscale's SSH interception and lands on the real
  # sshd, where root has no authorized key), so the local host is switched
  # directly with no --target-host. Computed from config.networking.hostName at
  # Nix eval time rather than a runtime `hostname` call, so it can never
  # disagree with which machine this actually is.
  localHost = config.networking.hostName;
  unknownHosts = filter (h: !(elem h self.hosts)) cfg.hosts;

  # Remote hosts first, the local host last. Switching this machine restarts
  # tailscaled, nix-daemon, caddy and cloudflared, and every remaining remote
  # deploy runs over Tailscale SSH from here — so doing ourselves in the middle
  # of the list would kick the ladder out from under the hosts after us.
  # cfg.hosts is ["basestar" "galactica" "raider"], which is exactly that.
  remoteHosts = filter (h: h != localHost) cfg.hosts;
  deployOrder = remoteHosts ++ optional (elem localHost cfg.hosts) localHost;

  # One host cannot be allowed to eat the whole unit budget: the unit would be
  # SIGKILLed with later hosts undeployed and no summary sent, which is the
  # cross-host coupling the per-host loop exists to remove.
  deployTimeoutMinutes = 60;
  deployTimeout = "${toString deployTimeoutMinutes}m";

  # The invariant: the unit's budget must exceed hosts × perHostTimeout by
  # enough for everything after the deploy loop to finish. Deploys are serial,
  # so the worst case is every host burning its full timeout — and it is
  # exactly that run whose report matters most, since it means the fleet is in
  # trouble. A fixed 3h against 3 × 60m left zero room: systemd would SIGKILL
  # the script mid-sweep and the operator would get a bare "unit failed" from
  # OnFailure instead of the per-host summary.
  #
  # The margin covers, worst case: the clone/fetch/reset, two 30s GitHub API
  # calls, the reachability probe (15s per remote host), the verification sweep
  # — whose slow part is `backup-status`, itself bounded at 120s per configured
  # source, and galactica has four — and the notify retries, which are bounded
  # at three attempts with 15s sleeps (~30s). An hour is comfortably above that
  # sum and keeps the arithmetic legible.
  sweepMarginMinutes = 60;
  unitTimeout = "${toString (length cfg.hosts * deployTimeoutMinutes + sweepMarginMinutes)}m";

  deployScript = pkgs.writeShellScriptBin "weekly-deploy" ''
    set -uo pipefail
    export PATH=${makeBinPath [
      pkgs.git
      # Deploys go through nixos-rebuild against .#nixosConfigurations, the
      # same attribute CI builds and caches (see the deploy loop below).
      pkgs.nixos-rebuild
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

    # ntfy runs on this very host (hosts/galactica/services/ntfy.nix) and is
    # reached the long way round: out through Cloudflare and back in through
    # this host's own cloudflared tunnel to Caddy. The final POST happens
    # moments after nixos-rebuild switched this host's generation and restarted
    # cloudflared and caddy, so a POST landing in that window fails for reasons
    # that have nothing to do with the report. Retry before believing it; the
    # caller decides what a permanent failure means.
    notify() {
      local attempt=1
      while :; do
        if ${config.constellation.backupNotify.script} "$1" "$2"; then
          return 0
        fi
        if [ "$attempt" -ge 3 ]; then
          return 1
        fi
        attempt=$((attempt + 1))
        sleep 15
      done
    }

    LOCAL_HOST="${localHost}"

    # Runs a command on host $1: locally when $1 is this host (Tailscale SSH
    # cannot authenticate a host to itself — same reason the local host is
    # switched without --target-host), over ssh otherwise. $2 is a single
    # command string, and
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
    # unit-wide, so git, nix and nixos-rebuild keep running without root's
    # dotfiles exactly as they do today.
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
    # This is the command that decides what gets deployed, and it is the only
    # one that was unguarded — `set -e` is deliberately off so the per-host
    # checks degrade instead of aborting, which means a bare failure here just
    # falls through. A stale .git/index.lock from a run killed mid-reset (the 3h
    # timeout, the MemoryMax OOM-killer, a reboot) does not stop `git fetch`,
    # which takes no such lock, so the fetch succeeds, the reset fails, and
    # $SHA becomes LAST week's commit — whose CI is green, so the precondition
    # passes and all three hosts get rolled backwards under a "3/3 healthy"
    # notification. The lock persists, so that repeats every week.
    git reset --hard origin/master || {
      notify "Weekly deploy failed on ${config.networking.hostName}" \
        "git reset --hard origin/master failed (checkout left at $(git rev-parse HEAD 2>/dev/null || echo unknown)). A stale .git/index.lock in $REPO is the usual cause. Nothing was deployed."
      exit 1
    }

    # An untracked file left in $REPO would be copied into the flake source,
    # changing `self` and therefore every host's toplevel out-path — none of
    # which CI ever built, so every host would fail on a cache miss under
    # max-jobs = 0. Nothing writes here today (`switch` passes --no-link, so
    # there is no result symlink), which is exactly why this should stay that
    # way by construction rather than by luck. Ignored files are left alone:
    # nix excludes them from the flake source anyway.
    git clean -fd || {
      notify "Weekly deploy failed on ${config.networking.hostName}" \
        "git clean -fd failed in $REPO - refusing to deploy from a dirty tree, whose out-paths CI would never have built. Nothing was deployed."
      exit 1
    }

    SHA=$(git rev-parse HEAD)
    ORIGIN_SHA=$(git rev-parse origin/master 2>/dev/null || echo "")

    # Belt and braces: the reset reported success, so prove it landed where it
    # was supposed to before anything downstream treats $SHA as "master".
    if [ -z "$ORIGIN_SHA" ] || [ "$SHA" != "$ORIGIN_SHA" ]; then
      notify "Weekly deploy failed on ${config.networking.hostName}" \
        "checkout is at $SHA but origin/master is ''${ORIGIN_SHA:-unknown} - refusing to deploy a tree that is not master. Nothing was deployed."
      exit 1
    fi

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

    # Reachability probe that doubles as known_hosts seeding: nixos-rebuild's
    # --target-host ssh would otherwise fail on an unknown host key. Tailscale
    # is the trust
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

    # nixos-rebuild against .#nixosConfigurations — the same attribute CI
    # builds and `just deploy` builds. Deploying anything else is what made
    # the first live run fail: a second evaluation that imports nixpkgs
    # itself drops the flake's revision metadata and produces
    # `nixos-system-basestar-26.05pre-git` where CI built and cached
    # `nixos-system-basestar-26.05.20260804.04607e1` — different derivations,
    # so the cache could never satisfy the deploy. Nix then fell back to
    # realising the closure, substituted thousands of paths fine, and finally hit the
    # trivial `allowSubstitutes = false` assembly derivations (check-sshd-config,
    # postgresql-configfile-check, unit-*.service) that MUST be built locally —
    # which max-jobs = 0 correctly refused. Deploying the same attribute CI
    # builds keeps the two aligned by construction instead of by keeping two
    # evaluation paths in sync.
    #
    # No --impure: nixosConfigurations evaluates purely, CI builds it purely,
    # so the deployer must too or the derivations diverge again.
    #
    # One invocation per host, so a failure is attributed to the host that
    # actually failed rather than to whichever batch it was in. Each is
    # best-effort — one failing never blocks the others, the sweep or the
    # summary — but its exit status is captured, never discarded. A deploy that
    # failed everywhere leaves every host answering readlink, systemctl and
    # backup-status perfectly well from its OLD generation, so without this the
    # run announces "3/3 healthy" and the operator reads that as "this week's
    # update landed" when nothing was deployed at all.
    #
    # --no-reexec is not optional here. For switch/boot/test, nixos-rebuild-ng
    # otherwise builds the TARGET's own
    # `config.system.build.nixos-rebuild` and execve's into it before doing any
    # real work. For basestar that binary is aarch64, and galactica has binfmt
    # live, so the exec SUCCEEDS and the whole of basestar's deploy — flake
    # evaluation, nix build, nix-copy-closure — would run under qemu emulation
    # inside this unit's 12G/3h budget; max-jobs = 0 cannot stop it because it
    # is not a nix build. For raider it would swap in raider's nixpkgs-unstable
    # CLI, making a future unstable change a silent dependency of this unit and
    # defeating the store-pinned PATH. The flag short-circuits in
    # nixos_rebuild/__init__.py before services.reexec() is called at all, so
    # that attribute is never even built.
    #
    # DEPLOY_ORDER is remote-first, local-last (see deployOrder above); the
    # sweep still reports in $HOSTS order.
    DEPLOY_ORDER="${concatStringsSep " " deployOrder}"
    declare -A DEPLOY_STATUS

    for h in $DEPLOY_ORDER; do
      printf '=== %s ===\n' "$h" >> "$STATE/last-deploy.log"
      if [ "$h" = "$LOCAL_HOST" ]; then
        # No --target-host: this machine cannot SSH to itself over Tailscale.
        timeout ${deployTimeout} nixos-rebuild switch --no-reexec \
          --flake "$REPO#$h" \
          >>"$STATE/last-deploy.log" 2>&1
      else
        timeout ${deployTimeout} nixos-rebuild switch --no-reexec \
          --flake "$REPO#$h" \
          --target-host "root@$h.bat-boa.ts.net" \
          >>"$STATE/last-deploy.log" 2>&1
      fi
      # `timeout` reports 124 when it fires, which flows through as this host's
      # deployRc and is spelled out in the summary rather than left as a
      # mystery number.
      DEPLOY_STATUS[$h]=$?
    done

    for h in $HOSTS; do
      run_on "$h" "systemctl start multi-user.target" 2>/dev/null || true
    done

    RESULTS=""
    HOST_PROBLEMS=0

    # The checks' stderr used to go to /dev/null, so CHECK_ERRS recorded which
    # check failed but never why — on an unattended weekly run that is the
    # difference between a diagnosable report and a mystery. Control flow is
    # unchanged; this only gives the discarded stream somewhere to land.
    : > "$STATE/last-checks.log"

    # Deploy outcome leads the body next to the lock line, so "did this week's
    # update actually land" is answerable without reading the per-host lines.
    DEPLOY_FAILED=""
    for h in $HOSTS; do
      [ "''${DEPLOY_STATUS[$h]}" -ne 0 ] && DEPLOY_FAILED="$DEPLOY_FAILED $h"
    done
    DEPLOY_FAILED="''${DEPLOY_FAILED# }"

    if [ -n "$DEPLOY_FAILED" ]; then
      DEPLOY_LINE="deploy FAILED on: $DEPLOY_FAILED (see $STATE/last-deploy.log)"
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

      # One nixos-rebuild per host means this is now genuinely this host's own
      # status, not the status of a batch it happened to be in.
      DEPLOY_RC=''${DEPLOY_STATUS[$h]}

      printf '=== %s ===\n' "$h" >> "$STATE/last-checks.log"

      GEN=$(run_on "$h" "readlink -f /run/current-system" 2>>"$STATE/last-checks.log") || {
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
      if FAILED_RAW=$(run_on "$h" "systemctl list-units --state=failed --no-legend --plain" 2>>"$STATE/last-checks.log"); then
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
      if ! BACKUPS=$(run_on "$h" "backup-status" 2>>"$STATE/last-checks.log"); then
        BACKUPS="[]"
        STALE="?"
        CHECK_ERRS="$CHECK_ERRS backup-status"
      elif [ -z "$BACKUPS" ]; then
        BACKUPS="[]"
        STALE="?"
        CHECK_ERRS="$CHECK_ERRS backup-status-empty"
      else
        STALE=$(printf '%s' "$BACKUPS" \
          | jq -r '[.[] | select(.ok | not) | .name] | join(",")' 2>>"$STATE/last-checks.log") || {
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
          if [ "$DEPLOY_RC" -eq 124 ]; then
            # `timeout`'s own exit code. Say so, rather than leaving the
            # operator to look up what 124 means at 2am.
            LINE="$LINE DEPLOY-FAILED(rc=124, timed out after ${deployTimeout})"
          elif [ "$GEN" = "unreachable" ]; then
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

    TOTAL=$(printf '%s' "$HOSTS" | wc -w)
    OK=$((TOTAL - HOST_PROBLEMS))
    PROBLEMS=$((HOST_PROBLEMS + LOCK_STALE))

    NOTIFY_SENT=true
    if [ "$PROBLEMS" -gt 0 ]; then
      notify "ACTION NEEDED - weekly deploy: $OK/$TOTAL healthy" "$SUMMARY" || NOTIFY_SENT=false
    else
      notify "Weekly deploy: $OK/$TOTAL healthy" "$SUMMARY" || NOTIFY_SENT=false
    fi

    # Written after the notification so notifySent records what actually
    # happened rather than what was about to be attempted.
    printf '%s' "$RESULTS" | jq -s \
      --arg sha "$SHA" --arg when "$(date -Is)" \
      --argjson lockAgeDays "$LOCK_AGE_DAYS" --arg lockCommitTime "$LOCK_COMMIT_ISO" \
      --arg deployFailedHosts "$DEPLOY_FAILED" \
      --argjson notifySent "$NOTIFY_SENT" \
      '{commit:$sha,ranAt:$when,lockAgeDays:$lockAgeDays,lockCommitTime:$lockCommitTime,deployFailedHosts:$deployFailedHosts,notifySent:$notifySent,hosts:.}' > "$STATE/last-run.json"

    # The report is the only artifact this unit exists to produce, so an
    # undelivered report has to fail the unit. Exiting 0 would leave no trace
    # anywhere: weekly-deploy would not appear in `systemctl --failed`, so next
    # week's sweep could not detect that this week's report was lost either.
    # Failing fires OnFailure=backup-notify@weekly-deploy and — more usefully —
    # leaves the unit red for the next run's own failed-units check to find.
    if [ "$NOTIFY_SENT" != true ]; then
      exit 1
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
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        # Every loop in the script iterates $HOSTS, so an empty list is not a
        # smaller run — it is a run that checks nothing and reports success:
        # the CI gate loop never executes so the precondition passes, the
        # deploy loop body never runs so nothing is deployed, and the sweep
        # sends "Weekly deploy: 0/0 healthy". CLAUDE.md invites editing
        # `tiers`, so this is one rename away.
        assertion = cfg.hosts != [];
        message = ''
          constellation.weeklyDeploy.hosts is empty, which would produce a
          green "0/0 healthy" report for a run that deployed and verified
          nothing. Set it explicitly, or check that self.tiers.tier1 in
          flake-modules/hosts.nix still exists and is non-empty.
        '';
      }
      {
        # Every host here becomes a flake attribute in
        # `nixos-rebuild switch --flake "$REPO#<host>"`, and the local one is
        # switched on THIS machine with no --target-host. A name that is not a
        # real host is at best an obscure 2am failure once a week and at worst
        # — for the local host — activates a different machine's configuration
        # here. self.hosts is the list nixosConfigurations is built from, so it
        # settles this at eval time.
        assertion = unknownHosts == [];
        message = ''
          constellation.weeklyDeploy.hosts contains
          ${concatStringsSep ", " unknownHosts}, which is not a host in this
          flake. `nixos-rebuild --flake "<repo>#<host>"` resolves against
          nixosConfigurations, built from self.hosts:
          ${concatStringsSep ", " self.hosts}. The local host (${localHost}) is
          switched on this machine directly, so a wrong name there would
          activate another host's configuration here.
        '';
      }
    ];

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
        # Derived from the host count and the per-host deploy timeout so it
        # cannot silently become too tight when a host joins the tier — see
        # unitTimeout above for the invariant and what the margin covers.
        TimeoutStartSec = unitTimeout;
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
