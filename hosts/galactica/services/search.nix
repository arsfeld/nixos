{config, ...}: let
  port = 8888;
  # Stable's searxng (2026-05-16) already carries the duckduckgo Sec-Fetch-* and
  # google 403 fixes that once justified pulling it from nixpkgs-unstable. Don't
  # bring the unstable override back without its python set: unstable searxng
  # rebuilt against stable's python3 fails its requirements check (babel>=2.18).
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
    configureUwsgi = true;
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
        # Brave rate-limits this IP (HTTP 429) with no engine-level fix.
        # Re-enable via `braveapi` engine + API key if desired.
        {
          name = "brave";
          disabled = true;
        }
        # startpage actively blocks SearXNG scraping (CAPTCHA) and wikidata's
        # SPARQL endpoint rate-limits (403) — both happen regardless of IP
        # (galactica is on a residential Videotron line, not a datacenter).
        # Disable to cut per-query latency and log noise.
        {
          name = "startpage";
          disabled = true;
        }
        {
          name = "wikidata";
          disabled = true;
        }
        # Bing tolerates scraping and gives a second independent source so
        # results aren't sourced solely from Google (which can itself 403).
        # Confirmed contributing on galactica.
        {
          name = "bing";
          disabled = false;
        }
        # mojeek blocks scrapers ("access denied"); needs their paid API. Off.
        {
          name = "mojeek";
          disabled = true;
        }
      ];
    };
  };
}
