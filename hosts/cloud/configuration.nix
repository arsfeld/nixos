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
  constellation.blog = {
    enable = true;
    domain = "blog.arsfeld.dev";
  };

  # Enable self-hosted Plausible Analytics
  constellation.plausible = {
    enable = true;
    domain = "plausible.arsfeld.dev";
  };

  # Enable Planka kanban board
  constellation.planka = {
    enable = true;
    domain = "planka.arsfeld.dev";
  };

  # Enable Siyuan note-taking application
  constellation.siyuan = {
    enable = true;
    domain = "siyuan.arsfeld.dev";
  };

  boot = {
    binfmt.emulatedSystems = ["x86_64-linux"];
  };

  constellation.backup.enable = true;
  constellation.services.enable = true;
  constellation.media.enable = true;
  # Enable Caddy metrics export (metrics-client and logs-client are enabled by default)
  constellation.metrics-client.caddy.enable = true;

  media.config.enable = true;

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
