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

  services.borgbackup.repos.micro = {
    authorizedKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO2ARxC0ATSCx+aqf66IkUOOwIw6CGwsH47uYXj1+P2U root@micro"];
    allowSubRepos = true;
  };
}
