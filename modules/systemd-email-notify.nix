# Systemd email notification module
#
# This module provides automatic email notifications for systemd service failures.
# It integrates with systemd's onFailure mechanism to send detailed failure reports
# including service status and recent logs.
#
# Features:
# - Automatic email on service failure
# - Rate limiting to prevent notification spam (1 hour cooldown)
# - Failure count tracking
# - HTML-formatted service status and logs
# - Integration with constellation email configuration
#
# The module automatically adds onFailure handlers to all systemd services,
# ensuring comprehensive monitoring coverage across the system.
#
# Example usage:
#   systemdEmailNotify = {
#     toEmail = "admin@example.com";
#     fromEmail = "noreply@example.com";
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  sendmail = pkgs.writeScript "sendmail" ''
    #!/bin/sh

    set -eu

    SERVICE_NAME="$1"
    COOLDOWN_SECONDS=3600  # 1 hour cooldown
    TIMESTAMP_FILE="/tmp/service_failure_$SERVICE_NAME.timestamp"
    FAILURE_COUNT_FILE="/tmp/service_failure_$SERVICE_NAME.count"

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
      echo "Rate limit: Not sending email for service $SERVICE_NAME. Failure count: $FAILURE_COUNT"
      exit 0
    fi

    date +%s > "$TIMESTAMP_FILE"

    # Update the timestamp file
    date +%s > "$TIMESTAMP_FILE"

    export EMAIL_TO=${config.systemdEmailNotify.toEmail}
    export EMAIL_FROM=${config.systemdEmailNotify.fromEmail}

    ${pkgs.send-email-event}/bin/send-email-event \
      "Service Failure $1 (Failure #$FAILURE_COUNT)" \
      "Failed Service: $1
        Failure Count: $FAILURE_COUNT

        Service Status:
        $(SYSTEMD_COLORS=1 systemctl status --full "$1" | ${pkgs.aha}/bin/aha -n)

        Recent Logs:
        $(SYSTEMD_COLORS=1 journalctl -u "$1" --reverse --lines=50 -b | ${pkgs.aha}/bin/aha -n)"

    echo 0 > "$FAILURE_COUNT_FILE"
  '';
in {
  options = {
    systemd.services = mkOption {
      type = with types;
        attrsOf (
          submodule {
            config.onFailure = ["email@%n.service"];
          }
        );
    };

    systemdEmailNotify.toEmail = mkOption {
      type = types.str;
      default = config.constellation.email.toEmail;
      description = ''
        Email address to send service failure notifications to.
        Defaults to the constellation email configuration if available.
      '';
    };

    systemdEmailNotify.fromEmail = mkOption {
      type = types.str;
      default = config.constellation.email.fromEmail;
      description = ''
        Email address to use as the sender for service failure notifications.
        Defaults to the constellation email configuration if available.
      '';
    };
  };

  config = {
    systemd.services."email@" = {
      description = "Sends a status mail via sendEmailEvent on service failures.";
      onFailure = mkForce [];
      serviceConfig = {
        ExecStart = "${sendmail} %i";
        Type = "oneshot";
      };
    };
  };
}
