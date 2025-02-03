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
    ${pkgs.send-email-event}/bin/send-email-event \
      "Service Failure $1 (Failure #$FAILURE_COUNT)" \
      "Failed Service: $1
        Failure Count: $FAILURE_COUNT

        Service Status:
        $(systemctl status --full "$1")

        Recent Logs:
        $(journalctl -u "$1" --reverse --lines=50)"

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
