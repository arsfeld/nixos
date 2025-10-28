{
  pkgs,
  config,
  self,
  ...
}: {
  age.secrets."restic-rest-auth".file = "${self}/secrets/restic-rest-auth.age";
  # Local backup: Root disk only (system state, no user data or media)
  services.rustic = {
    enable = true;
    profiles.nas = {
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "5h";
      };
      repository = {
        repository = "/mnt/storage/backups/rustic";
        password-file = config.age.secrets."restic-password".path;
      };
      backup = {
        init = true;
        snapshots = [
          {
            sources = ["/"];
            globs = [
              "!/dev"
              "!/proc"
              "!/sys"
              "!/mnt"
              "!/media"
              "!/tmp"
              "!/var/cache"
              "!/home/*/.cache"
              "!/home"
              "!/run"
              "!/var/lib/docker"
              "!/var/lib/containers"
              "!/var/lib/lxcfs"
            ];
            exclude-if-present = [".nobackup" "CACHEDIR.TAG"];
          }
        ];
      };
    };
  };
}
