{...}: {
  services.restic.server = {
    enable = true;
    extraFlags = ["--no-auth"];
    dataDir = "/mnt/storage/backups/restic-server";
  };
}
