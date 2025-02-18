{
  lib,
  pkgs,
  config,
  self,
  ...
}:
with lib; let
  sendEmailEvent = "${pkgs.send-email-event}/bin/send-email-event --email-from ${config.constellation.email.fromEmail} --email-to ${config.constellation.email.toEmail}";
in {
  options.constellation.email = with lib; {
    enable = mkOption {
      type = types.bool;
      default = true;
    };

    fromEmail = mkOption {
      type = types.str;
      default = "admin@rosenfeld.one";
    };

    toEmail = mkOption {
      type = types.str;
      default = "alex@rosenfeld.one";
    };
  };

  config = lib.mkIf config.constellation.email.enable {
    age.secrets.smtp_password.file = "${self}/secrets/smtp_password.age";
    age.secrets.smtp_password.mode = "444";

    programs.msmtp = {
      enable = true;
      accounts = {
        default = {
          auth = true;
          tls = true;
          from = config.constellation.email.fromEmail;
          host = "smtp.purelymail.com";
          port = 587;
          user = config.constellation.email.toEmail;
          passwordeval = "cat ${config.age.secrets.smtp_password.path}";
        };
      };
      defaults = {
        aliases = builtins.toFile "aliases" ''
          default: ${config.constellation.email.fromEmail}
          root: ${config.constellation.email.fromEmail}
        '';
      };
    };

    systemd.services."boot-mail-alert" = {
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "${sendEmailEvent} 'just booted'";
    };
    systemd.services."shutdown-mail-alert" = {
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "true";
      preStop = "${sendEmailEvent} 'is shutting down'";
    };
    systemd.services."weekly-mail-alert" = {
      serviceConfig.Type = "oneshot";
      script = "${sendEmailEvent} 'is still alive'";
    };
    systemd.timers."weekly-mail-alert" = {
      wantedBy = ["timers.target"];
      partOf = ["weekly-mail-alert.service"];
      timerConfig.OnCalendar = "weekly";
    };
  };
}
