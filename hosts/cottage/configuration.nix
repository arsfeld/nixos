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
    # ./disko-config.nix  # Disabled for nixos-infect - using existing ZFS pools
    ./services
    # ./backup  # Disabled until data pool is recreated
  ];

  # Enable all constellation modules
  constellation = {
    backup.enable = false; # Disabled until data pool is recreated
    common.enable = true;
    email.enable = true;
    media.enable = false; # Disabled until data pool is recreated
    podman.enable = true;
    services.enable = true;
    virtualization.enable = true;
  };

  # Enable media services with cottage-specific domain
  # Disabled until data pool is recreated
  # media.config = {
  #   enable = true;
  #   domain = "arsfeld.com";
  # };

  # Host-specific settings
  networking = {
    hostName = "cottage";
    hostId = "d4c0ffee"; # Required for ZFS

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

  # Bootloader.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";
  boot.loader.grub.useOSProber = true;

  # Early OOM killer
  services.earlyoom.enable = true;

  # Use latest kernel
  #boot.kernelPackages = pkgs.linuxPackages_latest;

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
  nixpkgs.config.packageOverrides = pkgs: {
    vaapiIntel = pkgs.vaapiIntel.override {enableHybridCodec = true;};
  };

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vaapiIntel
      vaapiVdpau
      libvdpau-va-gl
      intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
      vpl-gpu-rt
    ];
  };

  # System state version
  system.stateVersion = "25.05";
}
