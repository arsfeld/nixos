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

    #data = {
    #  paths = [ "/mnt/data/files" "/mnt/data/homes" "/var/nas" "/var/lib/plex" ];
    #  repo = "/mnt/backup/borg";
    #  encryption.mode = "none";
    #  extraArgs = "--progress";
    #  compression = "auto,zstd";
    #  startAt = "weekly";
    #};
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
    b2 = {
      paths = ["/home" "/var/data"];
      repository = "b2:arosenfeld-backup:backups";
      passwordFile = "/etc/secrets/restic";
      s3CredentialsFile = "/etc/secrets/b2.keys";
      extraOptions = [
        "--verbose=2"
        "--one-file-system"
      ];
      timerConfig = {
        OnCalendar = "Mon 03:00:00";
      };
    };
  };
}
