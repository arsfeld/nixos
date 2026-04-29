{
  config,
  pkgs,
  lib,
  ...
}: let
  port = 8888;
in {
  sops.secrets.searxng-env = {
    owner = "searx";
  };

  services.searx = {
    enable = true;
    package = pkgs.searxng;
    runInUwsgi = true;
    redisCreateLocally = true;
    environmentFile = config.sops.secrets.searxng-env.path;

    uwsgiConfig = {
      http = ":${toString port}";
      disable-logging = true;
    };

    settings = {
      general = {
        instance_name = "Search";
        privacypolicy_url = false;
        donation_url = false;
        contact_url = false;
        enable_metrics = false;
      };
      server = {
        secret_key = "$SEARXNG_SECRET_KEY";
        limiter = false;
        image_proxy = true;
        method = "GET";
      };
      ui = {
        static_use_hash = true;
        default_theme = "simple";
        theme_args.simple_style = "dark";
      };
      search = {
        safe_search = 0;
        autocomplete = "duckduckgo";
        formats = ["html" "json"];
      };
    };
  };

  media.gateway.services.search = {
    inherit port;
    exposeViaTailscale = true;
  };
}
