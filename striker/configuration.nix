# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ lib, config, pkgs, nixpkgs, modulesPath, ... }:

with lib;

{
  imports = [
    ./hardware-configuration.nix
    ../common/common.nix
    ../common/services.nix
    ../common/users.nix
    ./networking.nix
    ./services.nix
    ./backup.nix
  ];


  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    binfmt.emulatedSystems = [ "aarch64-linux" ];
    kernelModules = [ "kvm-intel" ];
    supportedFilesystems = [ "zfs" ];
  };


  fileSystems."/mnt/data/media" = {
    device = "192.168.31.10:/mnt/data/media";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "nofail" ];
  };
  fileSystems."/mnt/data/files" = {
    device = "192.168.31.10:/mnt/data/files";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "nofail" ];
  };
  fileSystems."/mnt/data/homes" = {
    device = "192.168.31.10:/mnt/data/homes";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "nofail" ];
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.05"; # Did you read the comment?

}

