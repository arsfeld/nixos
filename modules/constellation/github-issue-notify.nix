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

    update_failure_count

    if ! check_cooldown; then
      echo "Rate limit: Not creating GitHub issue for service $SERVICE_NAME. Failure count: $FAILURE_COUNT"
      exit 0
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
      --update-interval ${toString cfg.updateInterval} || {
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
