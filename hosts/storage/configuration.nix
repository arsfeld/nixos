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
      ./variables.nix
      ./hardware-configuration.nix
      ./zfs.nix
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

  virtualisation.docker.storageDriver = "zfs";

  boot = {
    #loader.systemd-boot.enable = true;
    #loader.efi.canTouchEfiVariables = true;
    binfmt.emulatedSystems = ["aarch64-linux"];
    kernelModules = ["kvm-intel" "ip6_tables"];
    supportedFilesystems = ["zfs" "bcachefs"];
  };

  services.earlyoom.enable = true;

  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;

  #boot.kernelParams = ["i915.enable_guc=3"];

  # systemd.email-notify.mailFrom = "admin@arsfeld.one";
  # systemd.email-notify.mailTo = "arsfeld@gmail.com";

  systemd.enableEmergencyMode = false;

  services.zfs.autoScrub.enable = true;
  services.zfs.autoScrub.interval = "monthly";
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
    ];
  };

  system.stateVersion = "24.05";
}
