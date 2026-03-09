{
  self,
  config,
  pkgs,
  ...
}: let
  mediaDomain = config.media.config.domain;
  nameToPort = import "${self}/common/nameToPort.nix";
  ntfyPort = nameToPort "ntfy";
  searchPort = nameToPort "search";
  invidiousPort = nameToPort "invidious";
in {
  media.gateway.services.ntfy = {
    port = ntfyPort;
    exposeViaTailscale = true;
    settings = {
      bypassAuth = true;
      funnel = true;
    };
  };
  media.gateway.services.search = {
    port = searchPort;
    settings = {
      bypassAuth = true;
      funnel = true;
    };
  };
  media.gateway.services.invidious = {
    port = invidiousPort;
    settings.funnel = true;
  };
  # NOTE: ntfy-env secret is now managed via sops in hosts/cloud/sops.nix
  # age.secrets.ntfy-env.file = "${self}/secrets/ntfy-env.age";
  # age.secrets.ntfy-env.mode = "444";

  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.${mediaDomain}";
      listen-http = ":${toString ntfyPort}";
      smtp-sender-addr = "smtp.purelymail.com:587";
      smtp-sender-user = "alex@rosenfeld.one";
      smtp-sender-from = "admin@rosenfeld.one";
    };
  };

  systemd.services.ntfy-sh.serviceConfig.EnvironmentFile = config.sops.secrets.ntfy-env.path;

  services.caddy.enable = true;

  services.searx = {
    enable = true;
    redisCreateLocally = true;
    settings = {
      server.port = searchPort;
      server.bind_address = "0.0.0.0";
      server.secret_key = "1cfa8e794a9009a13d0bc9491cc1d4ad676c9e968a814d263f74296b34314710";
      server.method = "GET";
      ui.center_alignment = true;
      ui.infinite_scroll = true;
      ui.results_on_new_tab = true;
      ui.query_in_title = true;
      ui.default_locale = "en";
      search.autocomplete = "duckduckgo";
      search.favicon_resolver = "duckduckgo";
      engines = [
        {
          name = "bing";
          engine = "bing";
          disabled = true;
        }
        {
          name = "startpage";
          engine = "startpage";
          disabled = false;
        }
        {
          name = "duckduckgo";
          disabled = true;
        }
        {
          name = "qwant";
          disabled = true;
        }
      ];
    };
  };

  services.invidious = {
    enable = false;
    port = invidiousPort;
    domain = "invidious.${mediaDomain}";
    database.createLocally = true;
    settings = {
      https_only = true;
      db.user = "invidious";
    };
  };
}
