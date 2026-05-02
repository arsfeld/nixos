{
  config,
  pkgs,
  inputs,
  lib,
  ...
}: let
  port = 8888;
  # Pull searxng from nixpkgs-unstable for engine fixes:
  # - duckduckgo: Sec-Fetch-* headers (e92f6b7, 2026-04-04) — fixes constant CAPTCHAs
  # - google: drop arc/async params + Android UA (a563127..c4f51aa, Mar 2026) — fixes 403s
  # Rebuild against stable's python3 so the NixOS uwsgi vassal (built from stable
  # pkgs) can construct a working Python env containing the searx module.
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config = pkgs.config;
  };
  searxng = pkgs-unstable.searxng.override {python3 = pkgs.python3;};
in {
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
      # Brave rate-limits this IP (HTTP 429) with no engine-level fix.
      # Re-enable via `braveapi` engine + API key if desired.
      engines = [
        {
          name = "brave";
          disabled = true;
        }
      ];
    };
  };

  media.gateway.services.search = {
    inherit port;
    exposeViaTailscale = true;
  };
}
