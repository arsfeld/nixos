{ config, pkgs, ... }:

{
  imports = [
    ../common/common.nix
    ../common/services.nix
    ../common/users.nix
    ./hardware-configuration.nix
  ];

  boot.supportedFilesystems = [ "zfs" ];

  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.device = "/dev/xvda"; #nodev" for efi only

  networking.useDHCP = false;
  networking.interfaces.eth0.useDHCP = false;
  networking.hostId = "ba2059f3";

  networking.interfaces.eth0 = {
    ipv4.addresses = [{
      address = "209.209.8.178";
      prefixLength = 24;
     }];
  };

  services.xe-guest-utilities.enable = true;

  networking.defaultGateway = "209.209.8.1";
  networking.nameservers = ["8.8.8.8"];
  networking.hostName = "virgon";

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.05"; # Did you read the comment?

}

