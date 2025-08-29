{
  lib,
  pkgs,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    inputs.nixos-apple-silicon.nixosModules.apple-silicon-support
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  # Enable Apple Silicon support
  hardware.asahi.enable = true;
  hardware.asahi.peripheralFirmwareDirectory = ./firmware;
  hardware.asahi.extractPeripheralFirmware = false; # Firmware already extracted
  hardware.asahi.setupAsahiSound = true;

  networking.hostName = "mbair";
  networking.networkmanager.enable = true;

  time.timeZone = lib.mkForce "America/Montreal";

  # i18n.defaultLocale is set by constellation.common to "en_CA.UTF-8"

  users.users.arosenfeld = {
    isNormalUser = true;
    extraGroups = ["wheel" "networkmanager"];
    packages = with pkgs; [
      firefox
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com"
    ];
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com"
  ];

  # vim, wget, git, tmux are already included via constellation.common
  environment.systemPackages = [
    # Add any mbair-specific packages here
  ];

  constellation.common.enable = true;
  constellation.gnome.enable = true;

  # Disable space-consuming features for MacBook Air
  constellation.gnome.gaming = false;
  constellation.gnome.virtualization = false;

  # Disable printing support to save space (removes hplip and samsung drivers)
  services.printing.enable = lib.mkForce false;

  # OpenSSH is enabled via constellation.common, only override specific settings
  services.openssh.settings.PermitRootLogin = "yes";

  # Space-saving configurations
  documentation.enable = false; # Disable documentation
  documentation.nixos.enable = false;
  documentation.man.enable = false;
  documentation.info.enable = false;
  documentation.doc.enable = false;

  # Limit systemd journal size
  services.journald.extraConfig = ''
    SystemMaxUse=100M
    SystemKeepFree=50M
  '';

  # Note: We keep firmware enabled as it may be needed for hardware support
  # (The constellation.common module already enables redistributable firmware)

  # System architecture is already defined in hardware-configuration.nix
  # nixpkgs.hostPlatform = "aarch64-linux";

  system.stateVersion = "25.11";
}
