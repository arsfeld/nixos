# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  boot.supportedFilesystems = [ "zfs" ];

  # Use the GRUB 2 boot loader.
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.device = "/dev/xvda"; #nodev" for efi only

  time.timeZone = "America/Toronto";

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

  nixpkgs.config.allowUnfree = true;

  zramSwap.enable = true;

  virtualisation.lxd.enable = true;

  virtualisation.docker = {
    enable = true;
    liveRestore = false;
    extraOptions = "--registry-mirror=https://mirror.gcr.io";
  };

  services.zerotierone = {
    enable = true;
    joinNetworks = [ "35c192ce9b7b5113"] ;
  };

  programs.zsh = {
      enable = true;
      ohMyZsh = {
          enable = true;
          theme = "agnoster";
      };
  };

  users.users.arosenfeld = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "docker" "lxd" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w" ]
;
    uid = 1000;
  };
  users.groups.arosenfeld.gid = 1000;

  services.openssh.enable = true;

  networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.05"; # Did you read the comment?

}

