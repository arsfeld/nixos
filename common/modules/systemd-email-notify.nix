{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  sendEmailEvent = import ../sendEmailEvent.nix {inherit lib pkgs;};

  sendmail = pkgs.writeScript "sendmail" ''
    #!/bin/sh

    COOLDOWN_SECONDS=3600  # 1 hour cooldown
    TIMESTAMP_FILE="/tmp/service_failure_$1.timestamp"

    # Check if the timestamp file exists and if enough time has passed
    if [ -f "$TIMESTAMP_FILE" ]; then
      LAST_NOTIFICATION=$(cat "$TIMESTAMP_FILE")
      CURRENT_TIME=$(date +%s)
      TIME_DIFF=$((CURRENT_TIME - LAST_NOTIFICATION))

      if [ $TIME_DIFF -lt $COOLDOWN_SECONDS ]; then
        echo "Rate limit: Not sending email for service $1. Last notification was $TIME_DIFF seconds ago."
        exit 0
      fi
    fi

    # Update the timestamp file
    date +%s > "$TIMESTAMP_FILE"
    ${sendEmailEvent {
      event = "Service Failure $1";
      extraContent = ''
        Failed Service: $1

        Service Status:
        $(systemctl status --full "$1")

        Recent Logs:
        $(journalctl -u "$1" --reverse --lines=50)
      '';
    }}
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
