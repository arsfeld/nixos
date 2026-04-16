{
  lib,
  pkgs,
  config,
  self,
  inputs,
  ...
}:
with lib; {
  imports = [
    ./hardware-configuration.nix
    ./disko-config.nix
    ./services
    ./backup
  ];

  # Enable all constellation modules
  constellation = {
    sops.enable = true;
    backup.enable = true;
    common.enable = true;
    email.enable = true;
    podman.enable = true;
    virtualization.enable = true;
  };

  # Publisher credential for claude-notify (authenticated ntfy.arsfeld.one
  # publishes). owner + mode let the user-mode script read it directly.
  sops.secrets."ntfy-publisher-env" = {
    sopsFile = ../../secrets/sops/ntfy-client.yaml;
    owner = "arosenfeld";
    mode = "0400";
  };

  # nofail is deliberate: pegasus must boot without the data pool.
  # Services that need the pool gate themselves via RequiresMountsFor.
  fileSystems."/mnt/storage" = {
    device = "/dev/disk/by-uuid/01cdd316-d539-42a4-b87c-de5d14d40c94";
    fsType = "btrfs";
    options = [
      "compress=zstd"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=30s"
    ];
  };

  # Enable media sync from storage
  # Syncs directories with .sync marker files to /mnt/storage/media
  constellation.mediaSync.enable = true;

  # Enable media services with pegasus-specific domain
  # Disabled until data pool is recreated
  # media.config = {
  #   enable = true;
  #   domain = "arsfeld.com";
  # };

  # Host-specific settings
  networking = {
    hostName = "pegasus";

    # Use DHCP as fallback on all interfaces
    useDHCP = true;

    # Ensure network doesn't block boot
    dhcpcd = {
      wait = "background"; # Don't wait for DHCP during boot
      extraConfig = ''
        # Shorter timeout for faster boot
        timeout 10
        # Don't wait for IPv6
        noipv6rs
        # Continue even without lease
        fallback
      '';
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";

  # Bootloader - systemd-boot for EFI
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.supportedFilesystems = ["btrfs"];

  # Early OOM killer
  services.earlyoom.enable = true;

  # Disable network wait online service
  systemd.services.NetworkManager-wait-online.enable = false;

  # Systemd boot resilience
  systemd = {
    # Allow boot to continue even if some units fail
    enableEmergencyMode = false; # Don't drop to emergency shell
  };

  # SMART monitoring
  services.smartd = {
    enable = true;
    notifications.mail.enable = true;
    notifications.test = true;
  };

  # Avahi for service discovery
  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      userServices = true;
    };
  };

  # GPG agent configuration
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = false;
    pinentryPackage = pkgs.pinentry-tty;
  };

  # Graphics support for hardware acceleration
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-vaapi-driver
      libvdpau-va-gl
      intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
      vpl-gpu-rt
    ];
  };

  # System state version
  system.stateVersion = "25.05";
}
