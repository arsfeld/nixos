# Constellation backup-summary module
#
# Generates and sends a weekly fleet-wide backup summary email on Sunday
# evening. Audits local and multi-client restic repos, rustic cold archives,
# and storage pool capacity, alerting operators to stale backups or
# unreachable remote targets.
{
  flake.modules.nixos.backup-summary = {
    key = "modules/backup/backup-summary";
    imports = [
      ({
        config,
        lib,
        pkgs,
        ...
      }: let
        cfg = config.constellation.backupSummary;
      in {
        options.constellation.backupSummary = {
          schedule = lib.mkOption {
            type = lib.types.str;
            default = "Sun *-*-* 20:00:00 UTC";
            description = "systemd OnCalendar schedule for the weekly summary email.";
          };

          toEmail = lib.mkOption {
            type = lib.types.str;
            default = config.constellation.email.toEmail;
            description = "Recipient email address.";
          };

          fromEmail = lib.mkOption {
            type = lib.types.str;
            default = config.constellation.email.fromEmail;
            description = "Sender email address.";
          };

          backrestPortalUrl = lib.mkOption {
            type = lib.types.str;
            default = "https://backrest.arsfeld.one/";
            description = "URL for the central Backrest web portal.";
          };
        };

        config = {
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
                "RUSTIC_PROFILE_SUBSTITUTE_ENV=true"
              ];
              EnvironmentFile = lib.mkIf (builtins.hasAttr "ovh-s3-env" config.sops.secrets) [
                config.sops.secrets."ovh-s3-env".path
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
      })
    ];
  };
}
