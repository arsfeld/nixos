{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  configDir = "/var/data";
  dataDir = "/mnt/data";
  puid = "5000";
  pgid = "5000";
  tz = "America/Toronto";
  email = "arsfeld@gmail.com";
  domain = "striker.arsfeld.net";
in {
  services.netdata.enable = true;

  services.code-server = {
    enable = true;
    user = "arosenfeld";
    group = "users";
    host = "0.0.0.0";
  };

  security.acme = {
    acceptTerms = true;
    certs = {
      "${domain}" = {
        #webroot = "/var/lib/acme/acme-challenge/";
        email = email;
        dnsProvider = "cloudflare";
        credentialsFile = "/var/lib/secrets/cloudflare";
      };
    };
  };

  users.users.caddy.extraGroups = ["acme"];

  services.home-assistant = {
    enable = true;
    config = {
      # https://www.home-assistant.io/integrations/default_config/
      default_config = {};
      # https://www.home-assistant.io/integrations/esphome/
      esphome = {};
      # https://www.home-assistant.io/integrations/met/
      met = {};
    };
  };

  services.caddy = {
    enable = true;
    email = email;
    virtualHosts = {
      "${domain}" = {
        useACMEHost = domain;
        serverAliases = ["striker"];
        extraConfig = ''
          root * /mnt/data
          file_server browse

          handle_path /stash/* {
            reverse_proxy http://localhost:9999
          }
        '';
      };
    };
  };
}
