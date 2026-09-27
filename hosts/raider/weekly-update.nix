# Autonomous weekly flake update and AI healing agent for raider
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.weeklyUpdate;

  weeklyUpdateScript = pkgs.writeShellScriptBin "weekly-update" ''
        set -euo pipefail

        export PATH="${makeBinPath [
      pkgs.git
      pkgs.nix
      pkgs.just
      pkgs.openssh
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.curl
      pkgs.systemd
      pkgs.nix-fast-build
      pkgs.niks3
      pkgs.nixos-rebuild
    ]}:/run/wrappers/bin:/run/current-system/sw/bin:/home/arosenfeld/.nix-profile/bin:/home/arosenfeld/.local/share/gemini/bin:$PATH"

        WORKSPACE="${cfg.workspaceDir}"
        STATE_DIR="${cfg.stateDir}"
        LOG_DIR="$STATE_DIR/logs"
        mkdir -p "$LOG_DIR" "$(dirname "$WORKSPACE")"

        TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
        RUN_LOG="$LOG_DIR/run_$TIMESTAMP.log"
        ERROR_LOG="$LOG_DIR/error_$TIMESTAMP.log"
        HEAL_LOG="$LOG_DIR/heal_$TIMESTAMP.log"
        exec > >(tee -a "$RUN_LOG") 2>&1

        echo "=== Starting Weekly Update: $(date) ==="

        notify_all() {
          local status="$1"
          local title="$2"
          local body="$3"

          echo "--> Sending ntfy alert: $title"
          if [ -f "${config.constellation.backupNotify.envFile}" ]; then
            set +u
            # shellcheck disable=SC1090
            . "${config.constellation.backupNotify.envFile}"
            set -u
            ${config.constellation.backupNotify.script} "$title" "$body" || true
          fi

          echo "--> Sending email alert: $title"
          ${pkgs.send-email-event}/bin/send-email-event \
            "$title" \
            "$body" \
            --email-from "${config.constellation.email.fromEmail}" \
            --email-to "${config.constellation.email.toEmail}" || true
        }

        on_failure() {
          local line="$1"
          local cmd="$2"
          echo "ERROR: Failed at line $line command '$cmd'"
          if [ -d "$WORKSPACE/.git" ]; then
            cd "$WORKSPACE"
            git rebase --abort 2>/dev/null || true
            git reset --hard origin/master || true
            git clean -fd || true
          fi
          local err_summary="Weekly update failed during execution at line $line ($cmd). See log: $RUN_LOG"
          if [ -s "$ERROR_LOG" ]; then
            err_summary="$err_summary"$'\n\n'"Build error:"$'\n'"$(head -n 25 "$ERROR_LOG")"
          fi
          notify_all "failure" "ACTION NEEDED: Weekly update failed on raider" "$err_summary"
          exit 1
        }
        trap 'on_failure $LINENO "$BASH_COMMAND"' ERR

        # 1. Sync isolated workspace
        echo "--> Syncing workspace at $WORKSPACE"
        if [ ! -d "$WORKSPACE/.git" ]; then
          git clone git@github.com:arsfeld/nixos.git "$WORKSPACE"
        fi
        cd "$WORKSPACE"
        git fetch origin master
        git checkout master
        git reset --hard origin/master
        git clean -fd

        INITIAL_SHA="$(git rev-parse HEAD)"

        # 2. Update flake inputs
        echo "--> Updating flake inputs"
        nix flake update

        if git diff --quiet flake.lock; then
          echo "--> flake.lock is already up to date. Nothing to do."
          exit 0
        fi

        # 3. Verification & AI Healing Loop
        echo "--> Testing tier-1 builds (dry-run)"
        HEALED=false
        HEAL_SUMMARY=""

        if ! just dry-run @tier1 >"$ERROR_LOG" 2>&1; then
          echo "--> Build/eval failed! Launching AI healing agent (agy)..."
          cat "$ERROR_LOG"

          PROMPT="You are an automated maintenance agent for this NixOS flake repository.
    We ran 'nix flake update', but 'just dry-run @tier1' failed with the following error:

    $(cat "$ERROR_LOG")

    Your task:
    1. Investigate and diagnose the root cause of the evaluation or build failure.
    2. Modify the Nix configuration in this repository to resolve the issue (for example: adding an insecure package to nixpkgs.config.permittedInsecurePackages, updating renamed module options, or patching obsolete configurations).
    3. Test your changes by running 'just dry-run @tier1'.
    4. Ensure 'git status' and 'git diff' contain only necessary, clean changes.
    5. Conclude your final response with a concise 1-2 paragraph summary of what failed and how you resolved it."

          if ! agy --print \
                   --dangerously-skip-permissions \
                   --effort high \
                   --print-timeout 15m \
                   "$PROMPT" >"$HEAL_LOG" 2>&1; then
            echo "--> agy healing command failed or timed out."
            cat "$HEAL_LOG"
            on_failure $LINENO "agy healing failed or timed out"
          fi

          echo "--> agy completed. Running independent verification gate..."
          if ! just dry-run @tier1 >"$ERROR_LOG" 2>&1; then
            echo "--> Independent verification failed after AI healing attempt."
            cat "$ERROR_LOG"
            on_failure $LINENO "independent verification failed after AI healing attempt"
          fi

          HEALED=true
          HEAL_SUMMARY="$(tail -n 20 "$HEAL_LOG")"
          echo "--> Independent verification PASSED after AI healing!"
        fi

        # 4. Commit and push
        echo "--> Committing changes"
        git add -A
        if [ "$HEALED" = true ]; then
          COMMIT_MSG=$(cat <<EOF
    chore: update flake inputs and heal build breakage

    [Healed by agy]
    $HEAL_SUMMARY
    EOF
    )
          git commit -m "$COMMIT_MSG"
        else
          git commit -m "chore: update flake inputs"
        fi

        echo "--> Pushing to origin/master"
        git pull --rebase origin master
        git push origin master

        NEW_SHA="$(git rev-parse HEAD)"

        # 5. Deploy to tier-1
        echo "--> Deploying to tier-1 hosts"
        just deploy @tier1

        # 6. Post-deploy health checks
        echo "--> Running post-deploy health checks"
        FAILED_SERVICES=""
        for host in basestar galactica raider; do
          echo "Checking failed units on $host..."
          if [ "$host" = "raider" ]; then
            HOST_FAILED="$(systemctl --failed --no-legend || true)"
            if [ -n "$HOST_FAILED" ]; then
              FAILED_SERVICES="$FAILED_SERVICES"$'\n'"[$host]"$'\n'"$HOST_FAILED"
            fi
          else
            if ! HOST_FAILED="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$host.bat-boa.ts.net" "systemctl --failed --no-legend" 2>&1)"; then
              FAILED_SERVICES="$FAILED_SERVICES"$'\n'"[$host] SSH connection failed or host unreachable"
            elif [ -n "$HOST_FAILED" ]; then
              FAILED_SERVICES="$FAILED_SERVICES"$'\n'"[$host]"$'\n'"$HOST_FAILED"
            fi
          fi
        done

        # 7. Success notification
        SUCCESS_BODY="Weekly update successfully completed from $INITIAL_SHA to $NEW_SHA."$'\n\n'
        if [ "$HEALED" = true ]; then
          SUCCESS_BODY="$SUCCESS_BODY"$'\n'"Build breakage was auto-healed by agy:"$'\n'"$HEAL_SUMMARY"$'\n\n'
        fi
        if [ -n "$FAILED_SERVICES" ]; then
          SUCCESS_BODY="$SUCCESS_BODY"$'\n'"Warning: Post-deploy health check detected failed units:"$'\n'"$FAILED_SERVICES"
          notify_all "warning" "Weekly Update: tier-1 deployed with service warnings" "$SUCCESS_BODY"
        else
          SUCCESS_BODY="$SUCCESS_BODY"$'\n'"All tier-1 hosts (basestar, galactica, raider) healthy."
          notify_all "success" "Weekly Update: tier-1 deployed successfully" "$SUCCESS_BODY"
        fi

        echo "=== Weekly Update finished successfully: $(date) ==="
  '';
in {
  options.services.weeklyUpdate = {
    enable = mkEnableOption "autonomous weekly update and healing service";

    workspaceDir = mkOption {
      type = types.str;
      default = "/home/arosenfeld/.local/share/nixos-weekly-update/nixos";
      description = "Dedicated isolated workspace directory for weekly updates.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/home/arosenfeld/.local/share/nixos-weekly-update";
      description = "Directory for weekly update logs and state.";
    };

    calendar = mkOption {
      type = types.str;
      default = "Sun *-*-* 03:00:00";
      description = "Systemd OnCalendar expression for weekly updates.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [
      weeklyUpdateScript
    ];

    systemd.services.weekly-update = {
      description = "Autonomous weekly flake update, healing and tier-1 deployment";
      after = ["network-online.target" "tailscaled.service"];
      wants = ["network-online.target" "tailscaled.service"];
      restartIfChanged = false;
      stopIfChanged = false;
      path = [
        pkgs.git
        pkgs.nix
        pkgs.just
        pkgs.openssh
        pkgs.coreutils
        pkgs.gnused
        pkgs.gnugrep
        pkgs.jq
        pkgs.curl
        pkgs.systemd
        pkgs.nix-fast-build
        pkgs.niks3
        pkgs.nixos-rebuild
      ];

      environment = {
        HOME = "/home/arosenfeld";
        NIKS3_AUTH_TOKEN_FILE = config.sops.secrets."niks3-api-token".path;
      };

      serviceConfig = {
        Type = "oneshot";
        User = "arosenfeld";
        Group = "users";
        ExecStart = "${weeklyUpdateScript}/bin/weekly-update";
        TimeoutSec = "3h";
      };
    };

    systemd.timers.weekly-update = {
      description = "Timer for autonomous weekly update";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.calendar;
        Persistent = true;
      };
    };
  };
}
