{...}: {
  services.restic.server = {
    enable = true;
    extraFlags = ["--no-auth"];
    dataDir = "/mnt/storage/backups/restic-server";
  };

  # /mnt/storage is mounted with "nofail" (hardware-configuration.nix), so
  # galactica boots fine without it. Without this guard, a boot with the pool
  # missing would let restic-rest-server create dataDir fresh on the root
  # SSD, and every client backup afterwards would report success into that
  # empty repo instead of the real one. Same lesson as pegasus's
  # backup-server.nix.
  systemd.services.restic-rest-server.unitConfig.RequiresMountsFor = "/mnt/storage";
}
