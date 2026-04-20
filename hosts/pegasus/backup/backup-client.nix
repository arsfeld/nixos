# Pegasus as a backup *client*: pushes /var/lib /home /root weekly to
# storage's restic REST server. Replaces the previous rustic profile
# configured via constellation.backup.
#
# The /mnt/storage/backups/restic-server exclusion keeps pegasus from
# recursively backing up the repo it serves to storage (pegasus also
# runs services.restic.server, see backup-server.nix).
{config, ...}: {
  constellation.backrest = {
    enable = true;
    repos.storage = {
      uri = "rest:http://storage.bat-boa.ts.net:8000/";
      passwordFile = config.sops.secrets."restic-password".path;
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
      ];
      excludeIfPresent = [".nobackup" "CACHEDIR.TAG"];
      schedule.cron = "30 3 * * 0";
    };
  };
}
