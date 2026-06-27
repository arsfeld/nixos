{
  config,
  pkgs,
  inputs,
  lib,
  ...
}: let
  port = 8888;
  # nixpkgs-unstable searxng for engine fixes, rebuilt against stable python3
  # so the NixOS uwsgi vassal can construct a working env.
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config = pkgs.config;
  };
  searxng = pkgs-unstable.searxng.override {python3 = pkgs.python3;};
in {
  media.services.search = {
    inherit port;
    tailscaleExposed = true;
  };

  sops.secrets.searxng-env = {
    owner = "searx";
  };

  services.searx = {
    enable = true;
    package = searxng;
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
      engines = [
        {
          name = "brave";
          disabled = true;
        }
        {
          name = "startpage";
          disabled = true;
        }
        {
          name = "wikidata";
          disabled = true;
        }
        {
          name = "bing";
          disabled = false;
        }
        {
          name = "mojeek";
          disabled = true;
        }
      ];
    };
  };
}
