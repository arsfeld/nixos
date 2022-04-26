{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  domain = "arsfeld.one";
  email = "arsfeld@gmail.com";
  dataDir = "/mnt/data";
  configDir = "/var/lib";
  puid = "5000";
  pgid = "5000";
  user = "media";
  group = "media";
  tz = "America/Toronto";
in {
  services.netdata.enable = true;

  security.acme = {
    acceptTerms = true;
    certs = {
      "${domain}" = {
        email = email;
        dnsProvider = "cloudflare";
        credentialsFile = "/var/lib/secrets/cloudflare";
        extraDomainNames = ["*.${domain}"];
      };
    };
  };

  services.duplicati = {
    enable = true;
    user = "root";
  };
  services.vaultwarden = {
    enable = true;
    backupDir = "/var/lib/vaultwarden-backup";
    config = {
      domain = "https://vault.${domain}";
      signupsAllowed = false;
    };
  };
  services.radarr = {
    enable = true;
    user = user;
    group = group;
  };
  services.sonarr = {
    enable = true;
    user = user;
    group = group;
  };
  services.bazarr = {
    enable = true;
    user = user;
    group = group;
  };
  services.prowlarr = {
    enable = true;
  };
  services.plex = {
    enable = true;
    user = user;
    group = group;
    openFirewall = true;
  };
  services.tautulli.enable = true;
  services.jellyfin = {
    enable = true;
    #openFirewall = true;
  };
  services.nzbhydra2 = {
    enable = true;
  };
  services.sabnzbd = {
    enable = true;
    user = user;
    group = group;
  };

  virtualisation.oci-containers.containers = {
    # plex = {
    #   image = "lscr.io/linuxserver/plex";
    #   environment = {
    #     PUID = puid;
    #     PGID = pgid;
    #     TZ = tz;
    #     VERSION = "latest";
    #   };
    #   environmentFiles = [
    #     "${configDir}/plex/env"
    #   ];
    #   volumes = [
    #     "${configDir}/plex:/config"
    #     "${dataDir}/media:/data"
    #   ];
    #   extraOptions = [
    #     "--device"
    #     "/dev/dri:/dev/dri"
    #     "--network=host"
    #   ];
    # };

    gluetun = {
      image = "qmcgaw/gluetun";
      environmentFiles = [
        "${configDir}/gluetun/env"
      ];
      volumes = [
        "${configDir}/gluetun:/gluetun"
      ];
      ports = ["8080:8080/tcp"];
      extraOptions = [
        "--cap-add=NET_ADMIN"
      ];
    };

    qbittorrent = {
      image = "ghcr.io/linuxserver/qbittorrent";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      volumes = [
        "${configDir}/qbittorrent:/config"
        "${dataDir}:${dataDir}"
      ];
      extraOptions = [
        "--network=container:gluetun"
      ];
    };

    stash = {
      image = "stashapp/stash:latest";
      volumes = [
        "${configDir}/stash:/root/.stash"
        "${dataDir}/media:/data"
      ];
      ports = [
        "9999:9999"
      ];
    };
  };

  users.users.caddy.extraGroups = ["acme"];

  networking.firewall.allowedTCPPorts = [22 80 443];

  services.caddy = {
    enable = true;
    email = email;
    package = (pkgs.callPackage ./caddy.nix {
      plugins = [
        "github.com/caddyserver/caddy-security"
      ];
      vendorSha256 = "0000000000000000000000000000000000000000000000000000";
    });
    virtualHosts = {
      "files.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          root * ${dataDir}
          file_server browse
        '';
      };
      "duplicati.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:8200";
      };
      "vault.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:8000";
      };
      "radarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''          reverse_proxy localhost:7878 {
                              transport http {
                                compression off
                              }
                            }'';
      };
      "sonarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:8989";
      };
      "bazarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:6767";
      };
      "qbittorrent.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:8080";
      };
      "prowlarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:9696";
      };
      "stash.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:9999";
      };
      "netdata.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:19999";
      };
      "tautulli.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:8181";
      };
      "jellyfin.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:8096";
      };
      "nzbhydra2.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:5076";
      };
      "sabnzbd.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy localhost:8888";
      };
    };
  };
}
