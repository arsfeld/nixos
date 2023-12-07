{...}: {
  services.restic.server = {
    enable = true;
    extraFlags = ["--private-repos"];
    dataDir = "/mnt/backup/restic-server";
  };
}
