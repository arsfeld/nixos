# Constellation backup-notify module
#
# One ntfy POST, two callers.
#
#   - Backrest calls `script` from a repo hook's actionCommand, because it
#     needs Backrest's own template expansion ({{.Repo.Id}} etc.) and so
#     cannot be a systemd unit.
#   - rustic's units point OnFailure= at backup-notify@<unit>.service, the
#     templated unit defined here.
#
# Same credential, same topic, one feed from the operator's side.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.backupNotify;

  # set -u is deliberate: an unset NTFY_BASIC_AUTH_B64 means the caller
  # forgot its EnvironmentFile, and a silent unauthenticated POST would
  # look like a working notification path until the day it matters.
  notifyScript = pkgs.writeShellScript "backup-notify" ''
    set -euo pipefail
    title="$1"
    body="$2"
    exec ${pkgs.curl}/bin/curl -sS --fail-with-body -X POST \
      -H "Authorization: Basic $NTFY_BASIC_AUTH_B64" \
      -H "Title: $title" \
      -H "Tags: floppy_disk,warning" \
      --data-binary "$body" \
      ${cfg.ntfyUrl}
  '';
in {
  options.constellation.backupNotify = {
    enable = mkEnableOption "shared ntfy notifier for backup orchestrators";

    ntfyUrl = mkOption {
      type = types.str;
      default = "https://ntfy.arsfeld.one/backups";
      description = "ntfy topic URL for backup failure notifications.";
    };

    envFile = mkOption {
      type = types.path;
      default = config.sops.secrets."ntfy-publisher-env".path;
      description = "EnvironmentFile providing NTFY_BASIC_AUTH_B64.";
    };

    script = mkOption {
      type = types.path;
      default = notifyScript;
      readOnly = true;
      description = ''
        Executable taking two positional arguments: title and body.
        Reads NTFY_BASIC_AUTH_B64 from the environment.
      '';
    };
  };

  config = mkIf cfg.enable {
    # %i is the failed unit's name without the .service suffix; callers
    # instantiate this as backup-notify@<unit>.service from OnFailure=.
    systemd.services."backup-notify@" = {
      description = "ntfy notification for failed backup unit %i";
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = cfg.envFile;
        ExecStart = ''${cfg.script} "${config.networking.hostName}: %i failed" "systemd unit %i failed on ${config.networking.hostName}. Run: journalctl -u %i -n 100 --no-pager"'';
      };
    };
  };
}
