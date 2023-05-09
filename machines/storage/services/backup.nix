{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}: {
  services.restic.server = {
    enable = true;
    appendOnly = true;
    extraFlags = ["--no-auth"];
    dataDir = "/mnt/backup/restic-server";
  };
}
