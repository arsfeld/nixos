{
  lib,
  pkgs,
  config,
  ...
}:
with lib; let
  email = "arsfeld@gmail.com";

  sendEmailEvent = {event}: ''
    printf "Subject: $(${pkgs.nettools}/bin/hostname) ${event} ''$(${pkgs.coreutils}/bin/date --iso-8601=seconds)\n\nzpool status:\n\n''$(${pkgs.zfs}/bin/zpool status)" | ${pkgs.msmtp}/bin/msmtp -a default ${email}
  '';
in {
  nixpkgs.config.packageOverrides = pkgs: {
    zfsStable = pkgs.zfsStable.override {enableMail = true;};
  };

  services.zfs.zed.enableMail = true;
  services.zfs.zed.settings = {
    ZED_EMAIL_ADDR = [email];
    ZED_NOTIFY_VERBOSE = true;
  };

  age.secrets.smtp_password.file = ../secrets/smtp_password.age;
  age.secrets.smtp_password.mode = "444";

  programs.msmtp = {
    enable = true;
    accounts = {
      default = {
        auth = true;
        tls = true;
        from = email;
        host = "smtp.gmail.com";
        port = 587;
        user = email;
        passwordeval = "cat ${config.age.secrets.smtp_password.path}";
      };
    };
    defaults = {
      aliases = builtins.toFile "aliases" ''
        default: ${email}
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
    script = sendEmailEvent {event = "just booted";};
  };
  systemd.services."shutdown-mail-alert" = {
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = "true";
    preStop = sendEmailEvent {event = "is shutting down";};
  };
  systemd.services."weekly-mail-alert" = {
    serviceConfig.Type = "oneshot";
    script = sendEmailEvent {event = "is still alive";};
  };
  systemd.timers."weekly-mail-alert" = {
    wantedBy = ["timers.target"];
    partOf = ["weekly-mail-alert.service"];
    timerConfig.OnCalendar = "weekly";
  };
}
