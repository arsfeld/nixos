{
  config,
  lib,
  pkgs,
  self,
  inputs,
  ...
}:
with lib; let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
in {
  imports = [
    ./disko-config.nix
    ./hardware-configuration.nix
    ./users.nix
    ./services
    ./backup
  ];

  constellation.backup.enable = true;
  # We're the netdata server, not a client.
  constellation.netdataClient.enable = false;
  constellation.services.enable = true;
  constellation.media.enable = true;
  constellation.podman.enable = true;

  # Development environment with packages but using podman (not docker)
  constellation.development = {
    enable = true;
    docker = false; # Keep using podman as the container runtime
  };
  services.isponsorblock.enable = false;
  constellation.githubIssueNotify.enable = true; # Enable isolated GitHub issue creation for systemd failures

  # Enable Home Assistant home automation platform
  constellation.home-assistant.enable = true;

  # Enable tablet sync for offline media viewing
  # Drop .sync files in media folders to mark for transcoding
  constellation.tabletSync.enable = true;

  # Enable sops-nix for secrets management
  constellation.sops.enable = true;

  # OpenCloud - lightweight file storage and collaboration platform
  constellation.opencloud.enable = true;

  # k3s Kubernetes cluster (server role)
  # Enable to migrate from Podman containers to Kubernetes
  # Set media.backend = "kubernetes" to deploy containers to k3s
  constellation.k3s = {
    enable = false; # Disabled by default, enable for k3s migration
    role = "server";
    # Storage has more resources and runs most workloads
    disableTraefik = true; # Using Caddy gateway
    disableServiceLB = true; # Using NodePort
  };

  # Tailscale Kubernetes Operator for service exposure (when k3s is enabled)
  # Replaces tsnsrv for *.bat-boa.ts.net access
  constellation.k8s-tailscale.enable = false; # Enable with k3s

  # Container backend: "podman" (default) or "kubernetes"
  # Set to "kubernetes" to deploy containers to k3s instead of Podman
  # media.backend = "kubernetes";

  # Tailscale VPN exit nodes via AirVPN
  # AirVPN credentials in env format for gluetun
  age.secrets.airvpn-env.file = "${self}/secrets/airvpn-env.age";
  # Tailscale auth key with pre-approved exit node capability
  # Generate at: https://login.tailscale.com/admin/settings/keys
  # Required settings: Reusable, Pre-approved, Exit node pre-approved
  age.secrets.tailscale-exit-key.file = "${self}/secrets/tailscale-exit-key.age";

  constellation.vpnExitNodes = {
    enable = true;
    # Use dedicated exit node auth key with pre-approved exit node capability
    tailscaleAuthKeyFile = config.age.secrets.tailscale-exit-key.path;
    nodes.brazil = {
      country = "Brazil";
      tailscaleHostname = "brazil-exit";
      # Use env format credentials for gluetun server selection
      credentialsFile = config.age.secrets.airvpn-env.path;
    };
  };

  # Enable qBittorrent with WireGuard VPN in network namespace
  services.qbittorrent-vpn.enable = true;

  # Enable Transmission with WireGuard VPN in network namespace
  services.transmission-vpn.enable = true;

  # Observability: Central hub for metrics and logs (disabled)
  # constellation.observability-hub.enable = true;

  media.config.enable = true;

  networking.hostName = "storage";
  networking.firewall.enable = false;
  # Enable IP forwarding for container networking and VPN exit nodes
  services.tailscale.useRoutingFeatures = "server";
  # Ensure bridge MAC matches router reservation (see hosts/router/services/kea-dhcp.nix)
  networking.interfaces.br0.macAddress = "00:e0:4c:bb:00:e3";
  nixpkgs.hostPlatform = "x86_64-linux";

  systemd.oomd.enableRootSlice = true;
  systemd.oomd.enableUserSlices = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  virtualisation.incus = {
    enable = true;
  };

  # Use latest kernel for bcachefs out-of-tree module (requires >= 6.16)
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # Use unstable bcachefs-tools for latest out-of-tree kernel module
  boot.bcachefs.package = pkgs-unstable.bcachefs-tools;

  boot = {
    binfmt.emulatedSystems = ["aarch64-linux"];
    # Kernel modules for containers with iptables (qbittorrent VPN)
    # Containers cannot load kernel modules themselves, so these must be loaded on host
    kernelModules = [
      "kvm-intel"
    ];
    supportedFilesystems = ["bcachefs"];
  };

  services.earlyoom.enable = true;

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
    # Use caddy-tailscale plugin WITH OAuth support to make Caddy join Tailnet as a single node
    # This replaces 64 separate tsnsrv instances, reducing CPU from 60.5% to ~2-5%
    # Using vendored erikologic/caddy-tailscale fork (PR #109) with OAuth client credentials support
    # OAuth allows ephemeral node registration with TS_API_CLIENT_ID + TS_API_CLIENT_SECRET
    package = pkgs.caddy-tailscale;
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
    intel-vaapi-driver = pkgs.intel-vaapi-driver.override {enableHybridCodec = true;};
  };

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
