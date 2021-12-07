# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../common/common.nix
    ../common/services.nix
    ../common/users.nix
  ];

  fileSystems."/data/media" = {
    device = "192.168.31.10:/mnt/data/media";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "nofail" ];
  };
  fileSystems."/data/files" = {
    device = "192.168.31.10:/mnt/data/files";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "nofail" ];
  };

  services.borgbackup.jobs =
    {
      # for a local backup
      dataBackup = {
        paths = "/var/data";
        repo = "/data/files/Backups/borg";
        compression = "zstd";
        encryption.mode = "none";
        startAt = "daily";
      };
    };

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  boot.loader.systemd-boot.enable = true;
  networking.hostName = "striker";

  boot = {
    kernelModules = [ "kvm-intel" ];
    supportedFilesystems = [ "zfs" ];
  };

  networking.useDHCP = false;
  networking.interfaces.enp12s0.useDHCP = true;
  networking.interfaces.br0.useDHCP = true;
  networking.bridges = {
    "br0" = {
      interfaces = [ "enp12s0" ];
    };
  };
  networking.hostId = "88ca1599";

  services.netdata.enable = true;

  services.syncthing = {
    enable = false;
    overrideDevices = true;
    overrideFolders = true;
    user = "media";
    group = "media";
    guiAddress = "0.0.0.0:8384";
    devices = {
      # "picon" = { id = "LLHMFJQ-NRACEUQ-5BK7NHF-XORU7H6-7PEBGUJ-AO2C3L6-LVUD4CJ-YFJHDAS"; };
      "libran" = { id = "BWNS7MB-PWINU5R-BRP4K34-K5RXNAS-KFHEKFQ-AYE4KP2-WXJ6M5A-A4PKHQM"; };
      "oracle" = { id = "QB77MGX-2D7EVZC-WHGBZ2F-RLTTAQJ-GYAYNOM-Q3RTYF3-PL7F435-WO4UWAN"; };
    };
    folders = {
      "data" = {
        id = "data";
        path = "/var/data";
        devices = [ "libran" "oracle" ];
      };
    };
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

