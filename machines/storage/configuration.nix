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
    ./zfs.nix
    ./cloud-sync.nix
    ./users.nix
    ./samba.nix
    ./backup.nix
    ./backup-kopia.nix
    ./services.nix
    (
      import ../../common/backup.nix (
        args
        // {repo = "u2ru7hl3@u2ru7hl3.repo.borgbase.com:repo";}
      )
    )
  ];

  networking.hostName = "storage";
  # networking.hostId = "86f58bee";
  networking.firewall.enable = false;

  virtualisation.docker.storageDriver = "zfs";

  boot = {
    #loader.systemd-boot.enable = true;
    #loader.efi.canTouchEfiVariables = true;
    binfmt.emulatedSystems = ["aarch64-linux"];
    kernelModules = ["kvm-intel"];
    #supportedFilesystems = ["zfs"];
  };

  services.zfs.autoScrub.enable = true;
  services.zfs.autoScrub.interval = "monthly";
  services.smartd.enable = true;
  services.smartd.notifications.mail.enable = true;
  services.smartd.notifications.test = true;
  services.sshguard.enable = true;

  services.printing.enable = true;
  services.printing.drivers = [pkgs.samsung-unified-linux-driver];
  services.printing.browsing = true;
  services.printing.allowFrom = ["all"]; # this gives access to anyone on the interface you might want to limit it see the official documentation
  services.printing.defaultShared = true; # If you want

  services.avahi.enable = true;
  services.avahi.publish.enable = true;
  services.avahi.publish.userServices = true;

  # services.xserver.enable = true;
  # services.xserver.desktopManager.xfce.enable = true;
  # services.xrdp.enable = true;
  # services.xrdp.defaultWindowManager = "${pkgs.xfce4-14.xfce4-session}/bin/xfce4-session";
}
