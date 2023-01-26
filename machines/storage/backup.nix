{
  config,
  pkgs,
  lib,
  ...
}:
with lib; {
  services.borgbackup.jobs = {
    # storage = {
    #   paths = [ "/var/nas" "/var/lib/plex" "/mnt/data/homes" ];
    #   environment.BORG_RSH = "ssh -i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no";
    #   encryption.passphrase = "ftQoF3LSr9aD7b";
    #   encryption.mode = "repokey-blake2";
    #   repo = "storage.arsfeld.ca:repo";
    #   # repo = "/mnt/backup/repo";
    #   extraArgs = "--progress";
    #   compression = "auto,zstd";
    #   startAt = [ ]; # "daily";
    # };

    data = {
      paths = [
        "/mnt/data/homes"
        "/var/lib"
        "/var/data"
        "/root"
      ];
      exclude = [
        # very large paths
        "/var/lib/docker"
        "/var/lib/systemd"
        "/var/lib/libvirt"

        "'**/.cache'"
        "'**/.nix-profile'"
      ];
      repo = "/mnt/backup/borg";
      encryption.mode = "none";
      extraArgs = "--progress";
      compression = "auto,zstd";
      startAt = "weekly";
    };
  };

  services.restic.backups = {
    nas = {
      paths = ["/var/data"];
      repository = "/mnt/data/backups/restic";
      passwordFile = "/etc/secrets/restic";
      timerConfig = {
        OnCalendar = "daily";
      };
    };
  };
}
