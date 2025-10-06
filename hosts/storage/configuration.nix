args @ {
  lib,
  pkgs,
  config,
  self,
  inputs,
  ...
}:
with lib; {
  imports = [
    ./disko-config.nix
    ./hardware-configuration.nix
    ./users.nix
    ./services
    ./backup
    ./cache.nix
  ];

  constellation.backup.enable = true;
  # We're the netdata server, not a client.
  constellation.netdataClient.enable = false;
  constellation.services.enable = true;
  constellation.media.enable = true;
  constellation.podman.enable = true;
  constellation.isponsorblock.enable = true;

  media.config.enable = true;

  networking.hostName = "storage";
  networking.firewall.enable = false;
  nixpkgs.hostPlatform = "x86_64-linux";

  systemd.oomd.enableRootSlice = true;
  systemd.oomd.enableUserSlices = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  virtualisation.incus = {
    enable = true;
  };

  boot = {
    binfmt.emulatedSystems = ["aarch64-linux"];
    kernelModules = ["kvm-intel" "ip6_tables"];
    supportedFilesystems = ["bcachefs"];
  };

  services.earlyoom.enable = true;

  boot.kernelPackages = pkgs.linuxPackages_6_12;

  systemd.services.NetworkManager-wait-online.enable = false;

  #boot.kernelParams = ["i915.enable_guc=3"];

  # systemd.email-notify.mailFrom = "admin@arsfeld.one";
  # systemd.email-notify.mailTo = "arsfeld@gmail.com";

  users.users.caddy.extraGroups = ["acme"];

  security.acme = {
    acceptTerms = true;
  };

  services.caddy = {
    enable = true;
  };

  services.tailscale.permitCertUid = "caddy";

  systemd.enableEmergencyMode = false;

  services.smartd = {
    enable = true;
    notifications.mail.enable = true;
    notifications.test = true;
  };

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      userServices = true;
    };
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
  nixpkgs.config.permittedInsecurePackages = [
    "aspnetcore-runtime-6.0.36"
    "aspnetcore-runtime-wrapped-6.0.36"
    "dotnet-sdk-6.0.428"
    "dotnet-sdk-wrapped-6.0.428"
  ];

  services.check-stock = {
    enable = true;
    urls.mystery-box-hr1 = {
      url = "https://frame.work/ca/en/products/framework-mystery-boxes?v=FRANHR0001";
      timerConfig = {
        OnCalendar = "hourly";
      };
    };
  };

  system.stateVersion = "24.05";
}
