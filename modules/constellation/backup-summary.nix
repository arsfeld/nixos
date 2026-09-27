# Constellation backup-summary module
#
# Generates and sends a weekly fleet-wide backup summary email on Sunday
# evening. Audits local and multi-client restic repos, rustic cold archives,
# and storage pool capacity, alerting operators to stale backups or
# unreachable remote targets.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.backupSummary;
in {
  options.constellation.backupSummary = {
    enable = mkEnableOption "weekly fleet backup summary email digest";

    schedule = mkOption {
      type = types.str;
      default = "Sun *-*-* 20:00:00 UTC";
      description = "systemd OnCalendar schedule for the weekly summary email.";
    };

    toEmail = mkOption {
      type = types.str;
      default = config.constellation.email.toEmail;
      description = "Recipient email address.";
    };

    fromEmail = mkOption {
      type = types.str;
      default = config.constellation.email.fromEmail;
      description = "Sender email address.";
    };

    backrestPortalUrl = mkOption {
      type = types.str;
      default = "https://backrest.arsfeld.one/";
      description = "URL for the central Backrest web portal.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [pkgs.backup-summary];

    # Deduplicate: Suppress the generic "is still alive" heartbeat timer on
    # hosts running the comprehensive backup digest.
    systemd.timers."weekly-mail-alert".enable = false;

    systemd.services.backup-summary = {
      description = "Weekly fleet backup summary email";
      after = ["network-online.target" "restic-rest-server.service"];
      wants = ["network-online.target"];
      unitConfig.RequiresMountsFor = "/mnt/storage";
      onFailure = ["backup-notify@backup-summary.service"];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        TimeoutStartSec = "10m";
        Restart = "no";
        Environment = [
          "EMAIL_TO=${cfg.toEmail}"
          "EMAIL_FROM=${cfg.fromEmail}"
          "RESTIC_PASSWORD_FILE=${config.sops.secrets."restic-password".path}"
          "BACKREST_PORTAL_URL=${cfg.backrestPortalUrl}"
        ];
        ExecStart = "${pkgs.backup-summary}/bin/backup-summary --send";
      };
    };

    systemd.timers.backup-summary = {
      description = "Weekly fleet backup summary timer";
      wantedBy = ["timers.target"];
      partOf = ["backup-summary.service"];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
      };
    };
  };
}
