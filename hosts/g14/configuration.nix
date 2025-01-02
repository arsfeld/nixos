{
  self,
  config,
  pkgs,
  lib,
  ...
}: {
  imports =
    self.nixosSuites.g14
    ++ [
      ./disko-config.nix
      ./hardware-configuration.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelPackages = pkgs.linuxPackages_zen;

  networking.hostName = "G14";

  virtualisation.incus = {
    enable = true;
    ui.enable = true;
  };
  networking.nftables.enable = true;

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

  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs" "bcachefs"];

  services.supergfxd.enable = true;

  services.asusd.enable = true;
  services.asusd.enableUserService = true;

  networking.bridges = {
    "br0" = {
      interfaces = ["enp4s0f4u1"];
    };
  };
  networking.useDHCP = false;
  networking.interfaces.br0.useDHCP = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "alt-intl";
  };

  # Configure console keymap
  console.keyMap = "us";

  system.stateVersion = "23.11"; # Did you read the comment?
}
