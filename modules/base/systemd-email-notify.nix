# Systemd email notification module
#
# This module provides automatic email notifications for systemd service failures.
# It integrates with systemd's onFailure mechanism to send detailed failure reports
# including service status and recent logs.
#
# Features:
# - Automatic email on service failure
# - Only mails units still failed once a deploy/boot has settled
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
  flake.modules.nixos.base = {
    key = "modules/base/systemd-email-notify";
    imports = [
      ({
        config,
        lib,
        pkgs,
        ...
      }: let
        sendmail = pkgs.writeScript "sendmail" ''
          #!/bin/sh

          set -eu

          SERVICE_NAME="$1"

          # Mail about steady state, not about transitions. A deploy's
          # switch-to-configuration stops and restarts many units at once,
          # and plenty fail along the way (a dependency stopped under them,
          # a restart racing its socket) before the start phase brings them
          # back. Boot is the same. So wait until no activation is running
          # and boot has finished, give Restart= units a moment to come back,
          # and send only if the unit is still failed. A unit that is failed
          # once things settle is exactly what deserves the mail.
          #
          # Never take /run/nixos/switch-to-configuration.lock to detect an
          # activation: switch-to-configuration grabs it non-blocking and
          # aborts if anyone holds it, even briefly.
          activating() {
            systemctl is-active --quiet nixos-rebuild-switch-to-configuration.service \
              || pgrep -f 'bin/switch-to-configuration' >/dev/null \
              || [ "$(systemctl is-system-running 2>/dev/null)" = starting ]
          }
          WAITED=0
          while activating && [ "$WAITED" -lt 1800 ]; do
            sleep 5
            WAITED=$((WAITED + 5))
          done
          sleep 60
          if ! systemctl is-failed --quiet "$SERVICE_NAME"; then
            echo "$SERVICE_NAME recovered (now $(systemctl is-active "$SERVICE_NAME" || true)); not sending."
            exit 0
          fi

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

          export EMAIL_TO=${config.systemdEmailNotify.toEmail}
          export EMAIL_FROM=${config.systemdEmailNotify.fromEmail}

          # Capture logs and status
          LOG_HTML=$(SYSTEMD_COLORS=1 journalctl -u "$1" --reverse --lines=50 -b | ${pkgs.aha}/bin/aha -n)
          STATUS_HTML=$(SYSTEMD_COLORS=1 systemctl status --full "$1" | ${pkgs.aha}/bin/aha -n)

          ${pkgs.send-email-event}/bin/send-email-event \
            "Service Failure $1 (Failure #$FAILURE_COUNT)" \
            "Failed Service: $1
              Failure Count: $FAILURE_COUNT

              Service Status:
              $STATUS_HTML

              Recent Logs:
              $LOG_HTML"

          echo 0 > "$FAILURE_COUNT_FILE"
        '';
      in {
        options = {
          systemd.services = lib.mkOption {
            type = with lib.types;
              attrsOf (
                submodule {
                  config.onFailure = ["email@%n.service"];
                }
              );
          };

          systemdEmailNotify.toEmail = lib.mkOption {
            type = lib.types.str;
            default = config.constellation.email.toEmail;
            description = ''
              Email address to send service failure notifications to.
              Defaults to the constellation email configuration if available.
            '';
          };

          systemdEmailNotify.fromEmail = lib.mkOption {
            type = lib.types.str;
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
            onFailure = lib.mkForce [];
            path = with pkgs; [
              nettools # provides hostname command
              coreutils
              util-linux
              procps # pgrep
              systemd
            ];
            # An instance may be mid-wait when the switch that caused it
            # changes this unit; restarting it would only lose the wait.
            restartIfChanged = false;
            serviceConfig = {
              ExecStart = "${sendmail} %i";
              Type = "oneshot";
              # Up to 30 min waiting for an activation, then a minute's grace.
              TimeoutStartSec = "40min";
            };
          };
        };
      })
    ];
  };
}
