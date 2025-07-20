# Constellation email notification module
#
# This module provides email notification capabilities for system events using
# msmtp as the mail transfer agent. It sends automated alerts for important
# system lifecycle events to keep administrators informed about system status.
#
# Key features:
# - Boot notifications when system starts up
# - Shutdown notifications before system powers off
# - Weekly heartbeat emails to confirm system is operational
# - SMTP authentication with encrypted password storage
# - Configurable sender and recipient addresses
# - Integration with PurelyMail SMTP service
#
# The module helps monitor system availability and detect unexpected reboots
# or prolonged downtime by sending regular status updates.
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
      description = ''
        Enable email notifications for system events.
        This will send emails on boot, shutdown, and weekly heartbeats
        to monitor system availability.
      '';
    };

    fromEmail = mkOption {
      type = types.str;
      default = "admin@rosenfeld.one";
      description = ''
        The email address to send notifications from.
        This should be a valid address configured in your SMTP service.
      '';
      example = "noreply@example.com";
    };

    toEmail = mkOption {
      type = types.str;
      default = "alex@rosenfeld.one";
      description = ''
        The email address to send notifications to.
        This is where all system alerts will be delivered.
      '';
      example = "admin@example.com";
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
