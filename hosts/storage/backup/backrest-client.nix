# Storage as a backup *client*: runs five Backrest plans pushing to
# four repos — local NAS, hetzner (system + user), and pegasus (one
# repo holding both system + user snapshots, distinguished by path
# set). Replaces the previous hand-rolled services.restic.backups
# profiles in backup-restic.nix.
#
# Retention, exclusion lists, and destination URIs are preserved 1:1
# from the prior restic config. Schedules are fixed-time crons spread
# across Sunday 02:30–07:30 local (previously weekly+RandomizedDelaySec).
#
# Per-plan ionice for the three idle-class profiles is not preserved
# in Phase A — Backrest runs one daemon with one scheduler; per-plan
# I/O class requires wrapping BACKREST_RESTIC_COMMAND and was deferred
# (see plan Open Questions: Storage I/O class). Observe impact during
# the first Sunday cycle.
{
  config,
  lib,
  ...
}: let
  # Kept separate from the system/user exclude lists because the nas
  # plan's geometry is unique (daily, all-paths-from-root, explicit
  # /home and /nix exclusion).
  nasExcludes = [
    "/dev"
    "/proc"
    "/sys"
    "/nix"
    "/mnt"
    "/media"
    "/tmp"
    "/var/cache"
    "/home/*/.cache"
    "/home"
    "/run"
    "/var/lib/docker"
    "/var/lib/containers"
    "/var/lib/lxcfs"
  ];

  systemExcludes = [
    "/home"
    "/mnt"
    "/dev"
    "/proc"
    "/sys"
    "/run"
    "/tmp"
    "/nix"
    "/var/cache"
    "/var/lib/docker"
    "/var/lib/containers"
    "/var/lib/lxcfs"
    "/var/lib/loki"
    "/var/lib/prometheus2"
  ];

  userExcludes = [
    "/mnt/storage/backups"
    "/mnt/storage/media"
    "/mnt/storage/homes"
    "/mnt/storage/legacy"
    "/home/*/.cache"
    "/home/*/.local/share/containers"
    "/home/*/.cargo"
    "/home/*/.rustup"
    "/home/*/.npm"
    "/home/*/.npm-global"
    "/home/*/.npm-packages"
    "/home/*/.nvm"
    "/home/*/.bun"
    "/home/*/go"
    "/home/*/.hex"
    "/home/*/.mix"
    "/home/*/.linuxbrew"
    "/home/*/.local/share/pnpm"
    "/home/*/.vscode-server"
    "/home/*/.cursor-server"
    "/home/*/.openvscode-server"
    "/home/*/.zed_server"
    "/home/*/.devpod"
    "/home/*/.claude"
    "/home/*/.claude-code-router"
    "/home/*/.codex"
    "/home/*/.copilot"
    "/home/*/.gemini"
    "/home/*/.qwen"
    "/home/*/.tailout"
    "/home/*/Takeout"
    "/home/*/Backup"
    "/home/*/torrents"
    "/home/*/.docker"
    "/home/*/.dropbox-dist"
    "/home/*/.wine"
    "/home/*/.nix-defexpr"
    "/home/*/.nix-profile"
    "/home/*/.terraform.d"
  ];

  remoteRetention = {
    daily = 7;
    weekly = 4;
    monthly = 6;
  };
in {
  # rclone creds for the hetzner repos. Mode 0400 matches the previous
  # services.restic.backups hetzner profile so Backrest-as-root reads
  # are unchanged.
  sops.secrets."hetzner-webdav-env" = {
    mode = "0400";
  };
  sops.secrets."hetzner-storagebox-ssh-key" = {
    mode = "0400";
    path = "/root/.ssh/hetzner_storagebox";
  };

  constellation.backrest = {
    enable = true;

    repos = {
      nas = {
        uri = "/mnt/storage/backups/restic";
        passwordFile = config.sops.secrets."restic-password".path;
      };
      hetzner-system = {
        uri = "rclone:hetzner:backups/restic-system";
        passwordFile = config.sops.secrets."restic-password".path;
        envFile = config.sops.secrets."hetzner-webdav-env".path;
      };
      hetzner = {
        uri = "rclone:hetzner:backups/restic";
        passwordFile = config.sops.secrets."restic-password".path;
        envFile = config.sops.secrets."hetzner-webdav-env".path;
      };
      pegasus = {
        uri = "rest:http://pegasus.bat-boa.ts.net:8000/";
        passwordFile = config.sops.secrets."restic-password".path;
      };
    };

    plans = {
      nas = {
        repo = "nas";
        paths = ["/"];
        excludes = nasExcludes;
        schedule.cron = "30 2 * * *";
        retention = {
          daily = 7;
          weekly = 5;
          monthly = 12;
        };
      };

      hetzner-system = {
        repo = "hetzner-system";
        paths = ["/"];
        excludes = systemExcludes;
        schedule.cron = "30 4 * * 0";
        retention = remoteRetention;
      };

      hetzner = {
        repo = "hetzner";
        paths = ["/home" "/mnt/storage"];
        excludes = userExcludes;
        schedule.cron = "30 5 * * 0";
        retention = remoteRetention;
      };

      pegasus-system = {
        repo = "pegasus";
        paths = ["/"];
        excludes = systemExcludes;
        schedule.cron = "30 6 * * 0";
        retention = remoteRetention;
      };

      pegasus = {
        repo = "pegasus";
        paths = ["/home" "/mnt/storage"];
        excludes = userExcludes;
        schedule.cron = "30 7 * * 0";
        retention = remoteRetention;
      };
    };
  };
}
