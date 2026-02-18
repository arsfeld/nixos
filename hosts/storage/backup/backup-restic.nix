{
  config,
  self,
  ...
}: {
  age.secrets."restic-rest-auth".file = "${self}/secrets/restic-rest-auth.age";
  age.secrets."hetzner-storagebox-ssh-key" = {
    file = "${self}/secrets/hetzner-storagebox-ssh-key.age";
    mode = "0400";
    path = "/root/.ssh/hetzner_storagebox";
  };

  services.restic.backups = {
    # Local backup: Root disk only (system state, no user data or media)
    nas = {
      paths = ["/"];
      exclude = [
        "/dev"
        "/proc"
        "/sys"
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
      repository = "/mnt/data/backups/restic";
      passwordFile = config.age.secrets."restic-password".path;
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "5h";
      };
    };

    # Remote backup: Full system including user data and critical media (Immich)
    servarica = {
      paths = ["/"];
      exclude = [
        "/dev"
        "/proc"
        "/sys"
        "/media"
        "/tmp"
        "/var/cache"
        "/home/*/.cache"
        "/run"
        "/var/lib/docker"
        "/var/lib/containers"
        "/var/lib/lxcfs"
        # Exclude local backup destinations to prevent recursion
        "/mnt/data/backups"
        "/mnt/storage/backups"
        # Note: /mnt/data and /mnt/storage are the same bcachefs filesystem mounted at different paths
        # To avoid backing up data twice, we exclude /mnt/storage entirely and only backup via /mnt/data
        "/mnt/storage"
        # Exclude /mnt/data/homes since /home is a separate mount of the same subvolume
        "/mnt/data/homes"
        # Exclude bulk media (movies, TV, music) via /mnt/data path - replaceable content
        "/mnt/data/media"
        # Keep /mnt/data/files - this contains important user files (729GB) that should be backed up
      ];
      repository = "rest:https://servarica.bat-boa.ts.net/";
      passwordFile = config.age.secrets."restic-password".path;
      extraOptions = ["sftp.command='ssh restic@servarica.bat-boa.ts.net'"];
      environmentFile = config.age.secrets."restic-rest-auth".path;
      initialize = false; # Repository already exists
      timerConfig = {
        OnCalendar = "weekly";
        RandomizedDelaySec = "1h";
      };
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 6"
      ];
    };

    # Pre-migration backup: User data to Hetzner Storage Box via SFTP
    hetzner = {
      paths = [
        "/mnt/storage/homes"
        "/mnt/storage/files"
      ];
      exclude = [];
      repository = "sftp:u547717@u547717.your-storagebox.de:backups/restic";
      passwordFile = config.age.secrets."restic-password".path;
      extraOptions = [
        "sftp.command='ssh -p 23 -i /root/.ssh/hetzner_storagebox -o StrictHostKeyChecking=accept-new u547717@u547717.your-storagebox.de -s sftp'"
      ];
      initialize = true;
      timerConfig = null; # Manual trigger only - no automatic schedule
    };
  };

  # Set I/O priority for backup jobs to idle class to prevent disk I/O congestion
  systemd.services = {
    restic-backups-nas.serviceConfig = {
      IOSchedulingClass = "idle";
    };
    restic-backups-servarica.serviceConfig = {
      IOSchedulingClass = "idle";
    };
    restic-backups-hetzner.serviceConfig = {
      TimeoutStartSec = "infinity";
    };
  };
}
