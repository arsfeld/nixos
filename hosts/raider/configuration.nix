{
  config,
  pkgs,
  lib,
  self,
  ...
}: let
  appimage = pkgs.callPackage (import ./appimage.nix) {};
in {
  imports = [./hardware-configuration.nix];

  boot.kernelParams = [
    "zswap.enabled=1"
    "mitigations=off"
    "splash"
    "quiet"
    "udev.log_level=0"
  ];

  boot.plymouth.enable = true;
  boot.plymouth.theme = "bgrt";

  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;

  # powerManagement.powertop.enable = true;

  services.system76-scheduler.enable = true;

  networking.hostName = "raider-nixos";

  systemd.services.NetworkManager-wait-online.enable = false;

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Remove zfs
  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs" "bcachefs"];

  virtualisation.incus = {
    enable = true;
    ui.enable = true;
  };
  networking.nftables.enable = true;

  boot.kernelPackages = pkgs.linuxPackages_zen;

  programs.coolercontrol.enable = true;

  programs = {
    gamemode.enable = true;
    gamescope = {
      enable = true;
      capSysNice = true;
    };
    steam = {
      enable = true;
      gamescopeSession.enable = true;
    };
  };

  #services.power-profiles-daemon.enable = false;

  # Set your time zone.
  time.timeZone = "America/Toronto";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_CA.UTF-8";

  # Configure keymap in X11
  services.xserver = {
    xkb.layout = "us";
    xkb.variant = "alt-intl";
  };

  # Configure console keymap
  console.keyMap = "us";

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.05"; # Did you read the comment?
}
