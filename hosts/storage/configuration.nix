args @ {
  lib,
  pkgs,
  config,
  suites,
  ...
}:
with lib; {
  imports =
    suites.storage
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

  virtualisation.docker.storageDriver = "zfs";

  boot = {
    #loader.systemd-boot.enable = true;
    #loader.efi.canTouchEfiVariables = true;
    binfmt.emulatedSystems = ["aarch64-linux"];
    kernelModules = ["kvm-intel" "ip6_tables"];
    supportedFilesystems = ["zfs" "bcachefs"];
  };

  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  #boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.kernelParams = ["i915.enable_guc=3"];

  systemd.email-notify.mailFrom = "admin@arsfeld.one";
  systemd.email-notify.mailTo = "arsfeld@gmail.com";

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
    enableSSHSupport = true;
    pinentryPackage = pkgs.pinentry-curses;
  };

  nixpkgs.config.packageOverrides = pkgs: {
    vaapiIntel = pkgs.vaapiIntel.override {enableHybridCodec = true;};
  };
  hardware.opengl = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vaapiIntel
      vaapiVdpau
      libvdpau-va-gl
      intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
    ];
  };
}
