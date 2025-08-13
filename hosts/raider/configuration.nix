{
  config,
  pkgs,
  lib,
  self,
  ...
}: let
  appimage = pkgs.callPackage (import ./appimage.nix) {};
in {
  imports = [
    ./hardware-configuration.nix
    ./disko-config.nix
  ];

  # Enable constellation modules
  constellation = {
    gnome.enable = true;
    gaming.enable = true;
    development.enable = true;
  };

  # Basic system configuration
  networking.hostName = "raider";

  systemd.services.NetworkManager-wait-online.enable = false;

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Boot appearance
  boot.plymouth.enable = true;
  boot.plymouth.theme = "bgrt";
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;

  # Remove zfs
  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs" "bcachefs"];

  networking.nftables.enable = true;

  # Additional system services specific to this machine
  programs.coolercontrol.enable = true;

  # Set your time zone
  time.timeZone = "America/Toronto";

  # Select internationalisation properties
  i18n.defaultLocale = "en_CA.UTF-8";

  # Configure keymap in X11
  services.xserver = {
    xkb.layout = "us";
    xkb.variant = "alt-intl";
  };

  # Configure console keymap
  console.keyMap = "us";

  # Enable the OpenSSH daemon
  services.openssh.enable = true;

  # Disable firewall for development
  networking.firewall.enable = false;

  # Disable suspend/hibernate
  services.logind = {
    lidSwitch = "ignore";
    lidSwitchDocked = "ignore";
    lidSwitchExternalPower = "ignore";
    extraConfig = ''
      HandlePowerKey=ignore
      HandleSuspendKey=ignore
      HandleHibernateKey=ignore
      IdleAction=ignore
      IdleActionSec=0
    '';
  };

  # Disable power management features
  powerManagement = {
    enable = true;
    powertop.enable = true;
  };

  # Disable GNOME auto-suspend
  services.xserver.displayManager.gdm.autoSuspend = false;

  # Mount games partition
  fileSystems."/mnt/games" = {
    device = "/dev/disk/by-uuid/d167c926-d34b-4185-b5d9-5235483b8c39";
    fsType = "btrfs";
    options = ["compress=zstd" "noatime"];
  };

  # System activation script for games directory
  system.activationScripts.gamesSetup = ''
    if [ -d /mnt/games ]; then
      mkdir -p /mnt/games/SteamLibrary
      chown -R arosenfeld:users /mnt/games 2>/dev/null || true
      chmod 755 /mnt/games

      if [ ! -L /home/arosenfeld/Games ]; then
        ln -sf /mnt/games /home/arosenfeld/Games 2>/dev/null || true
      fi
    fi
  '';

  # Environment variable for games location
  environment.sessionVariables = {
    GAMES_DIR = "/mnt/games";
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  system.stateVersion = "23.05";
}
