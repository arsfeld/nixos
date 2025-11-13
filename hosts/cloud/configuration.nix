{
  pkgs,
  self,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./services
    ./services.nix
    ./containers.nix
  ];

  constellation.docker.enable = true;
  constellation.sites.arsfeld-dev.enable = true;
  constellation.sites.rosenfeld-one.enable = true;

  # Blog service
  services.blog = {
    enable = true;
    domain = "blog.arsfeld.dev";
  };

  # Enable self-hosted Plausible Analytics
  services.plausible-analytics = {
    enable = true;
    domain = "plausible.arsfeld.dev";
  };

  # Enable Planka kanban board
  services.planka-board = {
    enable = true;
    domain = "planka.arsfeld.dev";
  };

  # Enable Siyuan note-taking application
  services.siyuan-notes = {
    enable = true;
    domain = "siyuan.arsfeld.dev";
  };

  # Enable Mydia metadata-relay service
  services.metadata-relay = {
    enable = true;
    domain = "metadata-relay.arsfeld.dev";
  };

  boot = {
    binfmt.emulatedSystems = ["x86_64-linux"];
  };

  constellation.backup.enable = true;
  constellation.services.enable = true;
  constellation.media.enable = true;

  # Enable sops-nix secret management
  constellation.sops.enable = true;

  # Define secrets using standard sops-nix options
  sops.secrets = {
    # Host-specific secrets (use defaultSopsFile set by constellation.sops)
    ntfy-env = {mode = "0444";};
    siyuan-auth-code = {
      owner = "root";
      group = "root";
    };
    metadata-relay-env = {mode = "0444";};
  };

  media.config = {
    enable = true;
    domain = "arsfeld.one";
  };

  # Enable dynamic Supabase management
  services.supabase = {
    enable = true;
    domain = "arsfeld.dev";
  };

  nixpkgs.hostPlatform = "aarch64-linux";

  #boot.kernelPackages = pkgs.linuxPackages_latest;

  #services.blocky.settings.customDNS.mapping."arsfeld.one" = "100.118.254.136";
  #services.redis.servers.blocky.bind = "100.66.38.77";
  #services.redis.servers.blocky.port = 6378;

  # systemd.email-notify.mailFrom = "admin@arsfeld.one";
  # systemd.email-notify.mailTo = "arsfeld@gmail.com";

  boot.tmp.cleanOnBoot = true;
  networking.hostName = "cloud";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22 80 443];
  };

  # This should be overriden by tailscale at some point
  networking.nameservers = ["1.1.1.1" "9.9.9.9"];

  services.fail2ban = {
    enable = true;
    ignoreIP = [
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
      "100.64.0.0/10"
    ];
  };

  security.acme.certs."arsfeld.dev" = {
    extraDomainNames = ["*.arsfeld.dev"];
  };

  # Plausible will use the wildcard certificate above
}
