# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
args @ {
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; {
  imports = [
    ./hardware-configuration.nix
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
    ../../common/mail.nix
    ./kopia.nix
    ./rclone.nix
    ./backup-battlestar.nix
    ./users.nix
    ./samba.nix
    ./services.nix
    (
      import ../../common/backup.nix (
        args
        // {repo = "u2ru7hl3@u2ru7hl3.repo.borgbase.com:repo";}
      )
    )
  ];

  networking.hostName = "storage";
  networking.hostId = "86f58bee";
  networking.firewall.enable = false;

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    binfmt.emulatedSystems = ["aarch64-linux"];
    kernelModules = ["kvm-intel"];
    supportedFilesystems = ["zfs"];
  };

  services.zfs.autoScrub.enable = true;
  services.zfs.autoScrub.interval = "monthly";
  services.smartd.enable = true;
  services.smartd.notifications.mail.enable = true;
  services.smartd.notifications.test = true;
  services.sshguard.enable = true;

  environment.systemPackages = with pkgs; [
    vim
    wget
  ];
}
