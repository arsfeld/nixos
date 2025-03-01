{config, ...}: {
  services.restic.backups = {
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
  };
}
