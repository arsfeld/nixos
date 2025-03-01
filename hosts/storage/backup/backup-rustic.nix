{
  pkgs,
  config,
  ...
}: {
  services.rustic = {
    enable = true;
    profiles.nas = {
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "5h";
      };
      repository = {
        repository = "/mnt/data/backups/rustic";
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
