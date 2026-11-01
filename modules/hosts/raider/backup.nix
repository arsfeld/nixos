# Backups: the backrest plan for the storage repo on galactica.
{
  configurations.nixos.raider.module = {config, ...}: {
    constellation.backrest = {
      repos.storage = {
        uri = "rest:http://galactica.bat-boa.ts.net:8000/";
        passwordFile = config.sops.secrets."restic-password".path;
        # galactica owns prune and check for this repo (it hosts the disk).
        # Three instances pruning one repository would contend for one lock.
        prune = null;
        check = null;
      };
      plans.system = {
        repo = "storage";
        paths = ["/var/lib" "/home" "/root"];
        excludes = [
          "/var/lib/docker"
          "/var/lib/containers"
          "/var/lib/systemd"
          "/var/lib/libvirt"
          "/var/lib/lxcfs"
          "/var/cache"
          "/nix"
          "/mnt"
          "**/.cache"
          "**/.nix-profile"
          # Rootless podman image storage. On galactica this was 1.56M files for
          # almost no bytes — two thirds of that repo's file count. Every layer is
          # re-pullable from a registry. Excluded fleet-wide so the same doesn't
          # accumulate here unnoticed.
          "**/.local/share/containers"
        ];
        excludeIfPresent = [".nobackup" "CACHEDIR.TAG"];
        # Interval-based scheduler matches laptop usage: runs ~24h after the
        # last successful run, catches up once after long suspensions
        # instead of stacking skipped cron entries.
        schedule = {
          maxFrequencyHours = 24;
          clock = "last-run";
        };
        # Was keep-all, which combined with the absent prune policy meant nothing
        # was ever removed from this repo. Matches the d7/w4/m6 that galactica
        # already uses for its hetzner and pegasus plans.
        retention = {
          daily = 7;
          weekly = 4;
          monthly = 6;
        };
      };
    };
  };
}
