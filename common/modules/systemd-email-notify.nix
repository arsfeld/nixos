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

    ${sendEmailEvent {
      event = "Service Failure";
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
