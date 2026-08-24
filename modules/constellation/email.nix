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

  # msmtpq gates every send behind a "am I online?" probe that shells out to
  # `ping debian.org`. ping lives in iputils and is *not* on a systemd unit's
  # PATH (which is only coreutils/findutils/gnugrep/gnused/systemd), so the
  # probe returned 127, msmtpq logged "host not connected", and queued the mail
  # instead of sending it — silently, forever, since the unit still exits 0.
  # That stranded 222 mails between 2026-05-27 and 2026-08-24.
  #
  # EMAIL_CONN_TEST=x skips the probe entirely. Nothing is lost by doing so:
  # msmtpq still queues the mail if the real msmtp call fails, so a genuine
  # network outage is handled by the actual send rather than by pinging an
  # unrelated third party. Any unit invoking msmtpq or msmtp-queue needs this.
  msmtpqEnv = {EMAIL_CONN_TEST = "x";};
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
    sops.secrets.smtp_password = {
      mode = "0444";
      sopsFile = config.constellation.sops.commonSopsFile;
    };

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
          passwordeval = "cat ${config.sops.secrets.smtp_password.path}";
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
      after = ["nss-lookup.target"];
      wants = ["nss-lookup.target"];
      environment = msmtpqEnv;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${sendEmailEvent} 'just booted'
        # Best-effort: at boot the network may not be up yet, and a failure
        # here is not evidence that mail is broken. Delivery is guaranteed by
        # flush-email-queue.timer, which retries every minute and *does* fail
        # loudly — so a genuine outage still raises an alarm there rather than
        # turning every boot into a false one.
        ${pkgs.msmtp}/bin/msmtp-queue -r || true
      '';
    };
    systemd.services."shutdown-mail-alert" = {
      wantedBy = ["multi-user.target"];
      after = ["nss-lookup.target"];
      wants = ["nss-lookup.target"];
      environment = msmtpqEnv;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "true";
      preStop = "${sendEmailEvent} 'is shutting down'";
    };
    systemd.services."weekly-mail-alert" = {
      environment = msmtpqEnv;
      serviceConfig.Type = "oneshot";
      script = "${sendEmailEvent} 'is still alive'";
    };
    systemd.timers."weekly-mail-alert" = {
      wantedBy = ["timers.target"];
      partOf = ["weekly-mail-alert.service"];
      timerConfig.OnCalendar = "weekly";
    };

    # Flush the msmtpq queue every minute so transient DNS / network
    # outages are absorbed without losing mail.
    systemd.tmpfiles.rules = [
      "d /root/.msmtp.queue 0700 root root - -"
    ];
    systemd.services."flush-email-queue" = {
      environment = msmtpqEnv;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.msmtp}/bin/msmtp-queue -r";
      };
    };
    systemd.timers."flush-email-queue" = {
      wantedBy = ["timers.target"];
      partOf = ["flush-email-queue.service"];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "1m";
      };
    };
  };
}
