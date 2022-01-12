{ lib, config, pkgs, nixpkgs, modulesPath, ... }:
{

  services.borgbackup.jobs =
    {
      # for a local backup
      dataBackup = {
        paths = "/var/data";
        repo = "/data/files/Backups/borg";
        compression = "zstd";
        encryption.mode = "none";
        startAt = "daily";
      };
    };
}