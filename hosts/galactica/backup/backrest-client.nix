# Storage as a backup *client*: runs five Backrest plans pushing to
# four repos — local NAS, hetzner, and pegasus, plus a fourth `storage`
# repo that carries no plans of its own (see its own comment below: it's
# the local path to the repository galactica's REST server serves to
# basestar/raider/pegasus, addressed here only so galactica can own prune
# and check for it). Both the system and user plans for hetzner/pegasus
# share the same repo (distinguished by path set). Replaces the previous
# hand-rolled services.restic.backups profiles in backup-restic.nix.
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

  # One repo per day, check at 09:00 and prune at 12:00 the same day. Nothing
  # lands on the 1st (rustic-ovh-prune) or on a Sunday (the 02:30-07:30 backup
  # block), and the three-hour gap keeps a prune from starting while that
  # repo's own check still holds the lock.
  #
  # readData re-reads that share of pack data during CHECK, and is only worth
  # it where reads are free (local disk). null = structure-only, which is
  # mandatory for the two remote repos: re-reading 2.9 TiB over rclone would
  # cost egress every month. That egress-avoidance applies to CHECK only.
  # `restic prune --max-unused N%` repacks partially-used packs — i.e. it
  # downloads and re-uploads them — independent of the check setting, so a
  # remote-repo prune does transfer pack data whenever it repacks. maxUnused
  # raises the threshold for the two remote repos (40% instead of the local
  # default 10%) to suppress most of that repacking; it doesn't eliminate it,
  # since fully-dead packs are deleted with no download either way.
  policies = {
    day,
    readData ? null,
    maxUnused ? 10,
  }: {
    check =
      {schedule.cron = "0 9 ${toString day} * *";}
      // lib.optionalAttrs (readData != null) {
        readDataSubsetPercent = readData;
      };
    prune = {
      schedule.cron = "0 12 ${toString day} * *";
      maxUnusedPercent = maxUnused;
    };
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
      local =
        {
          uri = "/mnt/storage/backups/restic";
          passwordFile = config.sops.secrets."restic-password".path;
        }
        // policies {
          day = 2;
          readData = 5;
        };

      # The repo galactica's own restic REST server serves, which basestar,
      # raider and pegasus all write to over rest://. Declared here with no
      # plans: galactica owns prune and check for it because it is the host
      # holding the disk, and three client instances pruning one repo would
      # just contend for the same lock.
      #
      # Addressed as a local path rather than rest://galactica:8000/ because
      # prune is I/O-heavy and this skips the HTTP round trip. Verified that
      # this path is the repo root (config, data, index, keys, locks,
      # snapshots), and restic locks are objects inside the repo, so a
      # local-path prune and a REST client still see each other's locks.
      storage =
        {
          uri = "/mnt/storage/backups/restic-server";
          passwordFile = config.sops.secrets."restic-password".path;
          # basestar writes here daily, so 48h is the right staleness bound.
          maxAgeHours = 48;
        }
        // policies {
          day = 3;
          readData = 5;
        };

      hetzner =
        {
          uri = "rclone:hetzner:backups/restic";
          passwordFile = config.sops.secrets."restic-password".path;
          envFile = config.sops.secrets."hetzner-webdav-env".path;
          # hetzner-system (30 4 * * 0) and hetzner (30 5 * * 0) are both
          # Sunday-only — weekly. 48h would report stale every week; 192h is
          # 8 days, one day of slack past the interval (matches ovh).
          maxAgeHours = 192;
        }
        // policies {
          day = 4;
          maxUnused = 40;
        };

      pegasus =
        {
          uri = "rest:http://pegasus.bat-boa.ts.net:8000/";
          passwordFile = config.sops.secrets."restic-password".path;
          # pegasus-system (30 6 * * 0) and pegasus (30 7 * * 0) are both
          # Sunday-only — weekly. Same 192h reasoning as hetzner above.
          maxAgeHours = 192;
        }
        // policies {
          day = 5;
          maxUnused = 40;
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

  # /mnt/storage is mounted with "nofail" (hardware-configuration.nix), so
  # galactica boots fine without it. Both the `local` and `storage` repos
  # above are local paths under /mnt/storage, and `storage` still carries
  # autoInitialize: true until a guid is written (backrest.nix's merge
  # script) — so without this guard, a boot with the pool missing would let
  # restic create a fresh empty repo on the root SSD, and every prune/check
  # afterwards would succeed into it silently.
  systemd.services.backrest.unitConfig.RequiresMountsFor = "/mnt/storage";
}
