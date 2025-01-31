{
  lib,
  pkgs,
  config,
  self,
  ...
}:
with lib; let
  email = "admin@rosenfeld.one";
in {
  age.secrets.smtp_password.file = "${self}/secrets/smtp_password.age";
  age.secrets.smtp_password.mode = "444";

  programs.msmtp = {
    enable = true;
    accounts = {
      default = {
        auth = true;
        tls = true;
        from = email;
        host = "smtp.purelymail.com";
        port = 587;
        user = "alex@rosenfeld.one";
        passwordeval = "cat ${config.age.secrets.smtp_password.path}";
      };
    };
    defaults = {
      aliases = builtins.toFile "aliases" ''
        default: ${email}
        root: ${email}
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
    script = "${pkgs.send-email-event}/bin/send-email-event 'just booted'";
  };
  systemd.services."shutdown-mail-alert" = {
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "true";
    preStop = "${pkgs.send-email-event}/bin/send-email-event 'is shutting down'";
  };
  systemd.services."weekly-mail-alert" = {
    serviceConfig.Type = "oneshot";
    script = "${pkgs.send-email-event}/bin/send-email-event 'is still alive'";
  };
  systemd.timers."weekly-mail-alert" = {
    wantedBy = ["timers.target"];
    partOf = ["weekly-mail-alert.service"];
    timerConfig.OnCalendar = "weekly";
  };
}
