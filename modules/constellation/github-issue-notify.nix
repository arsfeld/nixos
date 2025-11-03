# GitHub issue notification module for constellation
#
# This module provides isolated GitHub issue creation for systemd service failures.
# It runs in a separate security context from email notifications with a dedicated user.
#
# Security features:
# - Dedicated system user (github-notifier) with minimal permissions
# - No root HOME directory exposure
# - Isolated gh CLI authentication
# - No LLM integration (keeps issue creation simple and fast)
#
# Architecture:
# - github-issue@ systemd service template triggered by service failures
# - Separate from email@ service for independent operation
# - Services can trigger both email@ and github-issue@ via onFailure
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
with lib; let
  cfg = config.constellation.githubIssueNotify;

  # Script to create GitHub issues
  createGitHubIssueScript = pkgs.writeScript "create-github-issue" ''
    #!/bin/sh

    set -eu

    SERVICE_NAME="$1"
    COOLDOWN_SECONDS=3600  # 1 hour cooldown
    STATE_DIR="/var/lib/github-notifier"
    TIMESTAMP_FILE="$STATE_DIR/failure_$SERVICE_NAME.timestamp"
    FAILURE_COUNT_FILE="$STATE_DIR/failure_$SERVICE_NAME.count"
    MASS_FAILURE_LOG="$STATE_DIR/mass_failures.log"

    # Filtering configuration
    FILTERING_ENABLED="${toString cfg.filtering.enable}"
    IGNORE_EXIT_CODES="${toString (builtins.concatStringsSep "," (map toString cfg.filtering.ignoreExitCodes))}"
    TRANSIENT_WAIT_SECONDS="${toString cfg.filtering.transientWaitSeconds}"
    MASS_FAILURE_THRESHOLD="${toString cfg.filtering.massFailureThreshold}"
    MASS_FAILURE_WINDOW="${toString cfg.filtering.massFailureWindowSeconds}"

    # Ensure state directory exists
    mkdir -p "$STATE_DIR"

    update_failure_count() {
      FAILURE_COUNT=$(( $(cat "$FAILURE_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
      echo "$FAILURE_COUNT" > "$FAILURE_COUNT_FILE"
    }

    check_cooldown() {
      [ -f "$TIMESTAMP_FILE" ] || return 0
      LAST_NOTIFICATION=$(cat "$TIMESTAMP_FILE")
      CURRENT_TIME=$(date +%s)
      [ $((CURRENT_TIME - LAST_NOTIFICATION)) -ge $COOLDOWN_SECONDS ]
    }

    # Check for mass failure event
    check_mass_failure() {
      if [ "$FILTERING_ENABLED" != "1" ]; then
        return 1  # Not a mass failure (filtering disabled)
      fi

      CURRENT_TIME=$(date +%s)
      CUTOFF_TIME=$((CURRENT_TIME - MASS_FAILURE_WINDOW))

      # Log this failure
      echo "$CURRENT_TIME $SERVICE_NAME" >> "$MASS_FAILURE_LOG"

      # Count recent failures
      if [ -f "$MASS_FAILURE_LOG" ]; then
        # Clean up old entries and count recent ones
        RECENT_FAILURES=$(awk -v cutoff="$CUTOFF_TIME" '$1 >= cutoff { count++ } END { print count+0 }' "$MASS_FAILURE_LOG")

        # Clean the log file to remove old entries
        awk -v cutoff="$CUTOFF_TIME" '$1 >= cutoff' "$MASS_FAILURE_LOG" > "$MASS_FAILURE_LOG.tmp"
        mv "$MASS_FAILURE_LOG.tmp" "$MASS_FAILURE_LOG"

        if [ "$RECENT_FAILURES" -ge "$MASS_FAILURE_THRESHOLD" ]; then
          echo "Mass failure event detected: $RECENT_FAILURES services failed within $MASS_FAILURE_WINDOW seconds"
          return 0  # Is a mass failure
        fi
      fi

      return 1  # Not a mass failure
    }

    # Extract exit code and result from systemctl
    get_exit_info() {
      EXIT_CODE=$(systemctl show "$SERVICE_NAME" --property=ExecMainStatus --value)
      EXIT_RESULT=$(systemctl show "$SERVICE_NAME" --property=Result --value)

      # Return exit code (or 0 if not available)
      echo "''${EXIT_CODE:-0}"
    }

    # Check if exit code should be ignored
    should_ignore_exit_code() {
      if [ "$FILTERING_ENABLED" != "1" ]; then
        return 1  # Don't ignore (filtering disabled)
      fi

      EXIT_CODE="$1"

      # Check if exit code is in ignore list
      for IGNORED in $(echo "$IGNORE_EXIT_CODES" | tr ',' ' '); do
        if [ "$EXIT_CODE" = "$IGNORED" ]; then
          echo "Ignoring exit code $EXIT_CODE for $SERVICE_NAME (normal shutdown signal)"
          return 0  # Should ignore
        fi
      done

      return 1  # Don't ignore
    }

    # Check if service has recovered
    check_service_recovered() {
      if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
        echo "Service $SERVICE_NAME has recovered (now active)"
        return 0  # Service recovered
      fi
      return 1  # Still failed
    }

    update_failure_count

    if ! check_cooldown; then
      echo "Rate limit: Not creating GitHub issue for service $SERVICE_NAME. Failure count: $FAILURE_COUNT"
      exit 0
    fi

    # Check for mass failure event
    if check_mass_failure; then
      echo "Skipping issue creation due to mass failure event (deployment likely in progress)"
      exit 0
    fi

    # Get exit code information
    EXIT_CODE=$(get_exit_info)

    # Check if we should ignore this exit code
    if should_ignore_exit_code "$EXIT_CODE"; then
      # Wait to see if it's a transient failure
      if [ "$TRANSIENT_WAIT_SECONDS" -gt 0 ]; then
        echo "Waiting $TRANSIENT_WAIT_SECONDS seconds to check if service recovers..."
        sleep "$TRANSIENT_WAIT_SECONDS"

        if check_service_recovered; then
          echo "Service recovered after exit code $EXIT_CODE - not creating issue"
          exit 0
        fi
      fi
    fi

    # Wait for transient failures regardless of exit code
    if [ "$FILTERING_ENABLED" = "1" ] && [ "$TRANSIENT_WAIT_SECONDS" -gt 0 ]; then
      echo "Checking for transient failure (waiting $TRANSIENT_WAIT_SECONDS seconds)..."
      sleep "$TRANSIENT_WAIT_SECONDS"

      if check_service_recovered; then
        exit 0
      fi
    fi

    date +%s > "$TIMESTAMP_FILE"

    # Capture logs and status to temporary files
    LOG_FILE=$(mktemp)
    STATUS_FILE=$(mktemp)

    journalctl -u "$SERVICE_NAME" --reverse --lines=50 -b > "$LOG_FILE"
    systemctl status --full "$SERVICE_NAME" > "$STATUS_FILE" || true

    # Create GitHub issue (no LLM analysis for simplicity and speed)
    ${pkgs.send-email-event}/bin/create-github-issue \
      --repo "${cfg.repo}" \
      --service "$SERVICE_NAME" \
      --hostname "$(hostname)" \
      --status "$STATUS_FILE" \
      --journal "$LOG_FILE" \
      --failure-count "$FAILURE_COUNT" \
      --update-interval ${toString cfg.updateInterval} \
      --exit-code "$EXIT_CODE" || {
        echo "Failed to create GitHub issue for $SERVICE_NAME" >&2
        rm -f "$LOG_FILE" "$STATUS_FILE"
        exit 1
      }

    # Clean up temp files
    rm -f "$LOG_FILE" "$STATUS_FILE"

    # Reset failure count after successful notification
    echo 0 > "$FAILURE_COUNT_FILE"
  '';
in {
  options.constellation.githubIssueNotify = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable isolated GitHub issue creation for systemd failures.
        This runs in a separate security context from email notifications.
      '';
    };

    username = mkOption {
      type = types.str;
      default = "arsfeld";
      description = "GitHub username";
    };

    repo = mkOption {
      type = types.str;
      default = "arsfeld/nixos";
      description = "GitHub repository for systemd failure issues";
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to the GitHub token file (agenix secret)";
    };

    updateInterval = mkOption {
      type = types.int;
      default = 24;
      description = ''
        Hours before creating a new issue instead of updating an existing one.
        If a service fails multiple times within this interval, the existing
        issue will be updated with comments instead of creating duplicates.
      '';
    };

    filtering = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable intelligent filtering of transient failures and deployment events.
          When enabled, filters out normal shutdown signals, mass failures during
          deployments, and services that auto-recover.
        '';
      };

      ignoreExitCodes = mkOption {
        type = types.listOf types.int;
        default = [137 143]; # SIGKILL and SIGTERM
        description = ''
          Exit codes to ignore when filtering is enabled.
          137 = SIGKILL (killed), 143 = SIGTERM (terminated gracefully).
          These are normal during service restarts and deployments.
        '';
      };

      transientWaitSeconds = mkOption {
        type = types.int;
        default = 60;
        description = ''
          Seconds to wait before creating an issue to see if service recovers.
          Services that auto-recover within this time won't create issues.
        '';
      };

      massFailureThreshold = mkOption {
        type = types.int;
        default = 5;
        description = ''
          Number of services that must fail within the time window to
          trigger mass failure detection (likely a deployment event).
        '';
      };

      massFailureWindowSeconds = mkOption {
        type = types.int;
        default = 120;
        description = ''
          Time window in seconds for detecting mass failure events.
          If threshold is exceeded within this window, issue creation is suppressed.
        '';
      };
    };
  };

  options.systemd.services = mkOption {
    type = with types;
      attrsOf (
        submodule {
          config.onFailure = mkAfter ["github-issue@%n.service"];
        }
      );
  };

  config = mkIf cfg.enable {
    # Set tokenFile to the agenix secret path
    constellation.githubIssueNotify.tokenFile = mkDefault config.age.secrets.github-token.path;

    # Declare the github-token secret
    age.secrets.github-token = {
      file = "${self}/secrets/github-token.age";
      mode = "0400";
      owner = "github-notifier";
      group = "github-notifier";
    };

    # Create dedicated system user for GitHub notifications
    users.users.github-notifier = {
      isSystemUser = true;
      group = "github-notifier";
      home = "/var/lib/github-notifier";
      createHome = true;
      description = "GitHub issue notification service user";
    };

    users.groups.github-notifier = {};

    # Configure gh CLI authentication for the dedicated user
    systemd.services.configure-gh-notifier = {
      description = "Configure GitHub CLI authentication for github-notifier user";
      wantedBy = ["multi-user.target"];
      after = ["agenix.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "github-notifier";
        Group = "github-notifier";
      };
      script = ''
        mkdir -p /var/lib/github-notifier/.config/gh
        cat > /var/lib/github-notifier/.config/gh/hosts.yml << EOF
        github.com:
          oauth_token: $(cat ${cfg.tokenFile})
          user: ${cfg.username}
          git_protocol: https
        EOF
        chmod 600 /var/lib/github-notifier/.config/gh/hosts.yml
      '';
    };

    # Ensure required packages are available
    environment.systemPackages = with pkgs; [gh];

    # Create the github-issue@ systemd service template
    systemd.services."github-issue@" = {
      description = "Create GitHub issue for service failure: %i";
      after = ["configure-gh-notifier.service"];
      onFailure = mkForce []; # Prevent failure loops

      path = with pkgs; [
        gh
        nettools # provides hostname
        coreutils
        util-linux
        systemd # provides journalctl
      ];

      serviceConfig = {
        Type = "oneshot";
        User = "github-notifier";
        Group = "github-notifier";
        # Set HOME for gh CLI to find authentication
        Environment = "HOME=/var/lib/github-notifier";
        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = ["/var/lib/github-notifier"];
        NoNewPrivileges = true;
        # Allow reading system journals
        SupplementaryGroups = ["systemd-journal"];
        ExecStart = "${createGitHubIssueScript} %i";
      };
    };
  };
}
