args @ {
  lib,
  pkgs,
  config,
  self,
  inputs,
  ...
}:
with lib; {
  imports =
    self.nixosSuites.storage
    ++ [
      ./disko-config.nix
      ./variables.nix
      ./hardware-configuration.nix
      ./cloud-sync.nix
      ./users.nix
      ./samba.nix
      ./backup.nix
      ./services.nix
      ./borg.nix
      ./services/media.nix
      ./services/home.nix
    ];

  networking.hostName = "storage";
  networking.firewall.enable = false;
  nixpkgs.hostPlatform = "x86_64-linux";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  virtualisation.docker.storageDriver = "overlay2";

  boot = {
    #loader.systemd-boot.enable = true;
    #loader.efi.canTouchEfiVariables = true;
    binfmt.emulatedSystems = ["aarch64-linux"];
    kernelModules = ["kvm-intel" "ip6_tables"];
    supportedFilesystems = ["bcachefs"];
  };

  services.earlyoom.enable = true;

  boot.kernelPackages = pkgs.linuxPackages_6_10;
  boot.zfs.package = pkgs.zfs_unstable;

  systemd.services.NetworkManager-wait-online.enable = false;

  #boot.kernelParams = ["i915.enable_guc=3"];

  # systemd.email-notify.mailFrom = "admin@arsfeld.one";
  # systemd.email-notify.mailTo = "arsfeld@gmail.com";

  services.xserver = {
    enable = true;
    displayManager.gdm.enable = true;
    displayManager.gdm.autoSuspend = false;
    desktopManager.gnome.enable = true;
  };

  services.gnome.gnome-remote-desktop.enable = true;

  systemd.enableEmergencyMode = false;

  # services.zfs.autoScrub.enable = true;
  # services.zfs.autoScrub.interval = "monthly";
  services.smartd = {
    enable = true;
    notifications.mail.enable = true;
    notifications.test = true;
  };

  services.avahi = {
    enable = true;
    publish.enable = true;
    publish.userServices = true;
  };

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = false;
    pinentryPackage = pkgs.pinentry-tty;
  };

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

  system.stateVersion = "24.05";
}
