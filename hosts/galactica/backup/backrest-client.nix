# Storage as a backup *client*: runs five Backrest plans pushing to
# three repos — local NAS, hetzner, and pegasus. Both the system and
# user plans for hetzner/pegasus share the same repo (distinguished
# by path set). Replaces the previous hand-rolled services.restic.backups
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
  # Kept separate from the system/user exclude lists because the
  # local-system plan's geometry is unique (daily, all-paths-from-root,
  # explicit /home and /nix exclusion).
  localSystemExcludes = [
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

  # Deliberately short. This previously enumerated ~30 tool-specific dotfiles
  # (.cargo, .rustup, .npm, .nvm, .vscode-server, …), which was a maintenance
  # treadmill that never kept up with new tools, and it hid a real trap:
  # `/home/*/Takeout` silently kept 198 GiB of photos out of every backup from
  # 2024-08 to 2026-07, with nothing anywhere to surface the omission.
  #
  # Excluding a name pattern is cheap to write and expensive to notice. Prefer
  # backing up a few GiB of regenerable toolchain cache over quietly dropping
  # something irreplaceable that happens to match.
  userExcludes = [
    "/mnt/storage/backups"
    "/mnt/storage/media"
    "/mnt/storage/homes"
    "/mnt/storage/legacy"
    "/home/*/.cache"
    "/home/*/torrents"
    # Rootless podman image storage — the one name-pattern exclude that pays for
    # itself. Measured on the first OVH seed: 2.0M of 3.6M files for almost no
    # bytes, i.e. two thirds of the file count and index churn. Every layer is
    # re-pullable from a registry, so nothing irreplaceable matches this. That is
    # the test the comment above sets, and this is the case that passes it.
    "/home/*/.local/share/containers"
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
      local = {
        uri = "/mnt/storage/backups/restic";
        passwordFile = config.sops.secrets."restic-password".path;
      };
      hetzner = {
        uri = "rclone:hetzner:backups/restic";
        passwordFile = config.sops.secrets."restic-password".path;
        envFile = config.sops.secrets."hetzner-webdav-env".path;
        # hetzner-system (30 4 * * 0) and hetzner (30 5 * * 0) are both
        # Sunday-only — weekly. 48h would report stale every week; 192h is
        # 8 days, one day of slack past the interval (matches ovh).
        maxAgeHours = 192;
      };
      pegasus = {
        uri = "rest:http://pegasus.bat-boa.ts.net:8000/";
        passwordFile = config.sops.secrets."restic-password".path;
        # pegasus-system (30 6 * * 0) and pegasus (30 7 * * 0) are both
        # Sunday-only — weekly. Same 192h reasoning as hetzner above.
        maxAgeHours = 192;
      };
    };

    plans = {
      local-system = {
        repo = "local";
        paths = ["/"];
        excludes = localSystemExcludes;
        schedule.cron = "30 2 * * *";
        retention = {
          daily = 7;
          weekly = 5;
          monthly = 12;
        };
      };

      hetzner-system = {
        repo = "hetzner";
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
