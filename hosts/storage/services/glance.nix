{
  self,
  lib,
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;

  # Per-service display metadata: title override, category, and Glance icon ref.
  # Icons use Dashboard Icons (`di:`) to match the existing `<service>.png` convention.
  serviceMeta = {
    # Media
    plex = {
      category = "Media";
      icon = "di:plex";
    };
    jellyfin = {
      category = "Media";
      icon = "di:jellyfin";
    };
    audiobookshelf = {
      category = "Media";
      icon = "di:audiobookshelf";
    };
    kavita = {
      category = "Media";
      icon = "di:kavita";
    };
    komga = {
      category = "Media";
      icon = "di:komga";
    };
    overseerr = {
      category = "Media";
      icon = "di:overseerr";
    };
    tautulli = {
      category = "Media";
      icon = "di:tautulli";
    };
    stash = {
      category = "Media";
      icon = "di:stash";
    };
    romm = {
      category = "Media";
      icon = "di:romm";
    };
    ohdio = {
      category = "Media";
      icon = "di:radio";
    };
    mydia = {
      category = "Media";
      icon = "di:plex";
    };

    # Downloads
    transmission = {
      category = "Downloads";
      icon = "di:transmission";
    };
    qbittorrent = {
      category = "Downloads";
      icon = "di:qbittorrent";
    };
    jackett = {
      category = "Downloads";
      icon = "di:jackett";
    };
    autobrr = {
      category = "Downloads";
      icon = "di:autobrr";
    };
    bitmagnet = {
      category = "Downloads";
      icon = "di:bitmagnet";
    };
    flaresolverr = {
      category = "Downloads";
      icon = "di:flaresolverr";
    };
    pinchflat = {
      category = "Downloads";
      icon = "di:pinchflat";
    };
    headphones = {
      category = "Downloads";
      icon = "di:headphones";
    };

    # Management
    radarr = {
      category = "Management";
      icon = "di:radarr";
    };
    sonarr = {
      category = "Management";
      icon = "di:sonarr";
    };
    lidarr = {
      category = "Management";
      icon = "di:lidarr";
    };
    bazarr = {
      category = "Management";
      icon = "di:bazarr";
    };
    prowlarr = {
      category = "Management";
      icon = "di:prowlarr";
    };
    fileflows = {
      category = "Management";
      icon = "di:fileflows";
    };
    qui = {
      category = "Management";
      icon = "di:qbittorrent";
    };

    # Files
    syncthing = {
      category = "Files";
      icon = "di:syncthing";
    };
    seafile = {
      category = "Files";
      icon = "di:seafile";
    };
    resilio = {
      name = "Resilio Sync";
      category = "Files";
      icon = "di:resilio-sync";
    };
    filebrowser = {
      category = "Files";
      icon = "di:filebrowser";
    };
    filestash = {
      category = "Files";
      icon = "di:filestash";
    };
    nextcloud = {
      category = "Files";
      icon = "di:nextcloud";
    };
    opencloud = {
      category = "Files";
      icon = "di:owncloud";
    };
    cloud = {
      category = "Files";
      icon = "di:nextcloud";
    };
    transfer = {
      category = "Files";
      icon = "di:filebrowser";
    };

    # Photos
    immich = {
      category = "Photos";
      icon = "di:immich";
    };

    # Home / Automation
    hass = {
      name = "Home Assistant";
      category = "Home";
      icon = "di:home-assistant";
    };
    grocy = {
      category = "Home";
      icon = "di:grocy";
    };
    n8n = {
      category = "Home";
      icon = "di:n8n";
    };
    finance-tracker = {
      name = "Finance Tracker";
      category = "Home";
      icon = "di:firefly-iii";
    };
    actual = {
      name = "Actual Budget";
      category = "Home";
      icon = "di:actual-budget";
    };

    # Development
    forgejo = {
      category = "Development";
      icon = "di:forgejo";
    };
    ask = {
      category = "Development";
      icon = "di:open-webui";
    };
    ollama-api = {
      name = "Ollama API";
      category = "Development";
      icon = "di:ollama";
    };
    termix = {
      category = "Development";
      icon = "di:terminal";
    };

    # System
    grafana = {
      category = "System";
      icon = "di:grafana";
    };
    netdata = {
      category = "System";
      icon = "di:netdata";
    };
    beszel = {
      category = "System";
      icon = "di:beszel";
    };
    ntfy = {
      category = "System";
      icon = "di:ntfy";
    };

    # Security
    vault = {
      category = "Security";
      icon = "di:vaultwarden";
    };

    # Utilities
    speedtest = {
      name = "Speedtest Tracker";
      category = "Utilities";
      icon = "di:speedtest-tracker";
    };
    stirling = {
      name = "Stirling PDF";
      category = "Utilities";
      icon = "di:stirling-pdf";
    };
    search = {
      category = "Utilities";
      icon = "di:searxng";
    };
    yarr = {
      name = "Yarr";
      category = "Utilities";
      icon = "di:rss";
    };
  };

  # Services to omit from the dashboard entirely (self-references and
  # internal auth backends that aren't useful as user-facing bookmarks).
  hiddenServices = ["home" "www" "auth" "dex" "users"];

  capitalizeFirst = str:
    lib.toUpper (lib.substring 0 1 str) + lib.substring 1 (-1) str;

  serviceEntry = name: _svc: let
    meta = serviceMeta.${name} or {};
  in {
    title = meta.name or (capitalizeFirst name);
    category = meta.category or "Other";
    icon = meta.icon or "di:${name}";
    url = "https://${name}.${vars.domain}";
  };

  visibleServices =
    lib.filterAttrs (name: _: !lib.elem name hiddenServices)
    config.media.gateway.services;

  allEntries = lib.mapAttrsToList serviceEntry visibleServices;

  byCategory = lib.groupBy (e: e.category) allEntries;

  # Ordered category list; categories absent from the registry are dropped,
  # and any unknown categories surface at the end alphabetically.
  categoryOrder = [
    "Media"
    "Downloads"
    "Management"
    "Files"
    "Photos"
    "Home"
    "Development"
    "System"
    "Security"
    "Utilities"
    "Other"
  ];

  sortedCategoryNames = let
    known = lib.filter (c: byCategory ? ${c}) categoryOrder;
    extra =
      lib.sort (a: b: a < b)
      (lib.filter (c: !lib.elem c categoryOrder) (lib.attrNames byCategory));
  in
    known ++ extra;

  bookmarkGroups =
    map (cat: {
      title = cat;
      links =
        map (e: {
          inherit (e) title url icon;
        })
        (lib.sort (a: b: a.title < b.title) byCategory.${cat});
    })
    sortedCategoryNames;

  # Per-service monitor probe overrides. Glance's monitor widget does not
  # follow redirects, so services that auth-redirect (302) or path-redirect
  # (301) need either an explicit unauthenticated `check-url` or
  # `alt-status-codes` to be considered up.
  monitorOverrides = {
    plex.check-url = "https://plex.${vars.domain}/identity";
    jellyfin.check-url = "https://jellyfin.${vars.domain}/health";
    immich.check-url = "https://immich.${vars.domain}/api/server/ping";
    nextcloud.check-url = "https://nextcloud.${vars.domain}/status.php";
    seafile = {
      check-url = "https://seafile.${vars.domain}/api2/server-info/";
      timeout = "10s";
    };
    grafana.check-url = "https://grafana.${vars.domain}/api/health";
  };

  # Services that don't have a clean health endpoint and are reachable only
  # through Authelia get a 302 whitelist so the monitor reflects "gateway
  # routes correctly" rather than an authentication error.
  defaultAltStatusCodes = [301 302 401 403];

  monitorTargets = [
    "plex"
    "jellyfin"
    "sonarr"
    "radarr"
    "prowlarr"
    "transmission"
    "qbittorrent"
    "immich"
    "seafile"
    "grafana"
    "forgejo"
    "nextcloud"
  ];

  monitorSites = map (name: let
    meta = serviceMeta.${name} or {};
    override = monitorOverrides.${name} or {};
  in
    {
      title = meta.name or (capitalizeFirst name);
      url = "https://${name}.${vars.domain}";
      icon = meta.icon or "di:${name}";
      alt-status-codes = defaultAltStatusCodes;
    }
    // override)
  (lib.filter (n: visibleServices ? ${n}) monitorTargets);
in {
  services.glance = {
    enable = true;
    openFirewall = false;
    settings = {
      server = {
        host = "0.0.0.0";
        port = 8085;
      };
      branding = {
        app-name = "Storage";
        logo-text = "S";
      };
      pages = [
        {
          name = "Home";
          columns = [
            {
              size = "small";
              widgets = [
                {
                  type = "clock";
                  hour-format = "24h";
                }
                {
                  type = "calendar";
                  first-day-of-week = "monday";
                }
                {
                  type = "weather";
                  location = "Rouyn-Noranda, Quebec, Canada";
                  units = "metric";
                  hour-format = "24h";
                }
                {
                  type = "search";
                  search-engine = "https://www.perplexity.ai/search?q={QUERY}";
                  placeholder = "Ask Perplexity…";
                  new-tab = true;
                }
              ];
            }
            {
              size = "full";
              widgets = [
                {
                  type = "bookmarks";
                  groups = bookmarkGroups;
                }
              ];
            }
            {
              size = "small";
              widgets = [
                {
                  type = "server-stats";
                  servers = [
                    {
                      type = "local";
                      name = "storage";
                      mountpoints = {
                        "/" = {name = "Root";};
                        "/mnt/storage" = {name = "Storage";};
                      };
                      hide-mountpoints-by-default = true;
                    }
                  ];
                }
                {
                  type = "monitor";
                  cache = "5m";
                  title = "Services";
                  sites = monitorSites;
                }
              ];
            }
          ];
        }
      ];
    };
  };
}
