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

  constellation.podman.enable = true;
  constellation.sites.arsfeld-dev.enable = true;
  constellation.sites.rosenfeld-one.enable = true;
  constellation.blog = {
    enable = true;
    domain = "blog.arsfeld.dev";
  };

  boot = {
    binfmt.emulatedSystems = ["x86_64-linux"];
  };

  constellation.backup.enable = true;
  constellation.services.enable = true;
  constellation.media.enable = true;

  media.config.enable = true;

  # Supabase instances
  constellation.supabase = {
    enable = true;
    defaultDomain = "arsfeld.dev";
    
    instances = {
      finaro = {
        enable = true;
        subdomain = "finaro-api";
        port = 8080;  # Explicit port since we'll handle routing manually
        jwtSecret = "supabase-finaro-jwt";
        anonKey = "supabase-finaro-anon";
        serviceKey = "supabase-finaro-service";
        dbPassword = "supabase-finaro-dbpass";
        
        storage = {
          enable = true;
          bucket = "finaro-storage";
        };
        
        services = {
          realtime = true;
          auth = true;
          restApi = true;
          storage = true;
        };
        
        logLevel = "info";
      };
    };
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
}
