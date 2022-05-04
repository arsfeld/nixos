# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{
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
    ../common/common.nix
    ../common/services.nix
    ../common/users.nix
    ../common/mail.nix
    ./services.nix
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
  services.smartd.enable = true;
  services.smartd.notifications.mail.enable = true;
  services.smartd.notifications.test = true;
  services.sshguard.enable = true;

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
