{
  self,
  config,
  pkgs,
  ...
}: let
  mediaDomain = config.media.config.domain;
  ports = config.media.gateway.ports;
in {
  age.secrets.ntfy-env.file = "${self}/secrets/ntfy-env.age";
  age.secrets.ntfy-env.mode = "444";

  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.${mediaDomain}";
      listen-http = ":${toString ports.ntfy}";
      smtp-sender-addr = "smtp.purelymail.com:587";
      smtp-sender-user = "alex@rosenfeld.one";
      smtp-sender-from = "admin@rosenfeld.one";
    };
  };

  systemd.services.ntfy-sh.serviceConfig.EnvironmentFile = config.age.secrets.ntfy-env.path;

  services.caddy.enable = true;

  services.searx = {
    enable = true;
    redisCreateLocally = true;
    settings = {
      server.port = ports.search;
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
    port = ports.invidious;
    domain = "invidious.${mediaDomain}";
    database.createLocally = true;
    settings = {
      https_only = true;
      db.user = "invidious";
    };
  };
}
