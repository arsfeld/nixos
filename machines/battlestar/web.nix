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
in {
  users.users.caddy.extraGroups = ["acme"];

  networking.firewall.allowedTCPPorts = [22 80 443];

  services.caddy = {
    enable = true;
    email = email;
    package = pkgs.xcaddy;
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
        extraConfig = ''
          reverse_proxy localhost:8000
        '';
      };
      "radarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:7878
          @api {
            not path /api/*
          }
          authorize @api with admin_policy
        '';
      };
      "sonarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:8989
          @api {
            not path /api/*
          }
          authorize @api with admin_policy
        '';
      };
      "bazarr.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:6767
          authorize with admin_policy
        '';
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
        extraConfig = ''
          reverse_proxy localhost:9999
          authorize with admin_policy
        '';
      };
      "netdata.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:19999
          authorize with admin_policy
        '';
      };
      "tautulli.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:8181
          authorize with admin_policy
        '';
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
        extraConfig = ''
          reverse_proxy localhost:8888
          authorize with admin_policy
        '';
      };
      "hass.${domain}" = {
        useACMEHost = domain;
        extraConfig = "reverse_proxy striker:8123";
      };
      "code.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy localhost:4444  
        '';
      };
      "dev.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          reverse_proxy striker:4444
        '';
      };
      "auth.${domain}" = {
        useACMEHost = domain;
        extraConfig = "authenticate with myportal";
      };
    };

    globalConfig = ''
      order authenticate before respond
      order authorize before reverse_proxy

      security {
        local identity store localdb {
          realm local
          path /var/lib/caddy/.config/caddy/users.json
        }
        authentication portal myportal {
          enable identity store localdb
          cookie domain ${domain}
          cookie lifetime 604800 # 7 days in seconds
          ui
          transform user {
            match email ${email}
            action add role authp/user
          }
        }
        authorization policy admin_policy {
            set auth url https://auth.${domain}
            allow roles authp/user
        }
      }
    '';
  };
}
