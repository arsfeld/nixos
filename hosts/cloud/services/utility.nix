{
  self,
  config,
  pkgs,
  ...
}: let
  mediaDomain = config.media.config.domain;
  services = config.media.gateway.services;
in {
  # NOTE: ntfy-env secret is now managed via sops in hosts/cloud/sops.nix
  # age.secrets.ntfy-env.file = "${self}/secrets/ntfy-env.age";
  # age.secrets.ntfy-env.mode = "444";

  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.${mediaDomain}";
      listen-http = ":${toString services.ntfy.port}";
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
      server.port = services.search.port;
      server.bind_address = "0.0.0.0";
      server.secret_key = "secret-indeed";
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
    port = services.invidious.port;
    domain = "invidious.${mediaDomain}";
    database.createLocally = true;
    settings = {
      https_only = true;
      db.user = "invidious";
    };
  };

  # Redis instance for metadata-relay service
  services.redis.servers.metadata-relay = {
    enable = true;
    bind = "127.0.0.1";
    port = 6380; # Use different port to avoid conflicts
    save = [
      [900 1] # Save after 900 seconds if at least 1 key changed
      [300 10] # Save after 300 seconds if at least 10 keys changed
      [60 10000] # Save after 60 seconds if at least 10000 keys changed
    ];
  };
}
