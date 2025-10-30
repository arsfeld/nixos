{
  config,
  self,
  ...
}: {
  age.secrets."restic-rest-auth".file = "${self}/secrets/restic-rest-auth.age";

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
        # Exclude bulk media (movies, TV, music) - replaceable content
        "/mnt/storage/media"
        "/mnt/storage/files"
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
  };
}
