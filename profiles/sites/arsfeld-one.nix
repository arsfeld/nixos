{
  lib,
  config,
  self,
  ...
}:
with lib; let
  utils = import ./site-utils.nix {inherit lib self;};
  services = import "${self}/common/services.nix" {};

  domain = "arsfeld.one";
  email = "arsfeld@gmail.com";
  bypassAuth = [
    "auth"
    "autobrr"
    "dns"
    "flaresolverr"
    "grafana"
    "immich"
    "nextcloud"
    "ntfy"
    "ollama-api"
    "search"
    "sudo-proxy"
    "transmission"
    "vault"
  ];
  cors = ["sudo-proxy"];
  funnels = ["yarr" "jellyfin"];

  configs = utils.generateConfigs {
    cloud = services.cloud;
    storage = services.storage;
  };
  tsnsrvConfigs = utils.generateTsnsrvConfigs configs funnels config;
  hosts = utils.generateHosts configs domain bypassAuth cors;
in {
  security.acme.certs."${domain}" = {
    extraDomainNames = ["*.${domain}"];
  };

  services.tsnsrv.services = tsnsrvConfigs;

  services.caddy.email = email;

  services.caddy.globalConfig = utils.generateCaddyGlobalConfig;

  services.caddy.extraConfig = utils.generateCaddyExtraConfig domain;

  services.caddy.virtualHosts =
    hosts
    // {
      "nextcloud.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          rewrite /.well-known/carddav /remote.php/dav
          rewrite /.well-known/caldav /remote.php/dav

          reverse_proxy storage:8099
        '';
      };
    };
}
