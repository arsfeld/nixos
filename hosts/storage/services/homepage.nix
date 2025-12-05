{
  self,
  lib,
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;

  # Mapping for homepage-specific service metadata
  serviceMappings = {
    # Storage Services
    plex = {
      category = "Media";
      icon = "plex.png";
      description = "Watch movies & TV shows";
      widget.type = "tautulli";
      widget.url = "https://tautulli.${vars.tsDomain}";
      widget.key = "{{HOMEPAGE_VAR_TAUTULLI_KEY}}";
    };
    transmission = {
      category = "Downloads";
      icon = "transmission.png";
      description = "Torrent client";
      widget.type = "transmission";
      widget.url = "https://transmission.${vars.tsDomain}";
      widget.username = "{{HOMEPAGE_VAR_TRANSMISSION_USERNAME}}";
      widget.password = "{{HOMEPAGE_VAR_TRANSMISSION_PASSWORD}}";
      widget.rpcUrl = "/transmission/";
    };
    radarr = {
      category = "Management";
      icon = "radarr.png";
      description = "Movie management";
      widget.type = "radarr";
      widget.url = "https://radarr.${vars.tsDomain}";
      widget.key = "{{HOMEPAGE_VAR_RADARR_KEY}}";
    };
    sonarr = {
      category = "Management";
      icon = "sonarr.png";
      description = "TV management";
      widget.type = "sonarr";
      widget.url = "https://sonarr.${vars.tsDomain}";
      widget.key = "{{HOMEPAGE_VAR_SONARR_KEY}}";
    };
    lidarr = {
      category = "Management";
      icon = "lidarr.png";
      description = "Music management";
      widget.type = "lidarr";
      widget.url = "https://lidarr.${vars.tsDomain}";
      widget.key = "{{HOMEPAGE_VAR_LIDARR_KEY}}";
    };
    # prowlarr is not listed in services.nix but kept here as example
    # prowlarr = { category = "Management"; icon = "prowlarr.png"; description = "Index management"; widget.type = "prowlarr"; widget.url = "https://prowlarr.${vars.tsDomain}"; widget.key = "{{HOMEPAGE_VAR_PROWLARR_KEY}}"; };
    netdata = {
      category = "System";
      icon = "netdata.png";
      description = "System monitoring";
    };
    grafana = {
      category = "System";
      icon = "grafana.png";
      description = "Metrics dashboard";
    };
    scrutiny = {
      category = "System";
      icon = "compact-disc";
      description = "Disk health (SMART)";
    };
    duplicati = {
      category = "System";
      icon = "duplicati.png";
      description = "System backup";
    };
    syncthing = {
      category = "Files";
      icon = "syncthing.png";
      description = "File synchronization";
    };
    resilio = {
      name = "Resilio Sync";
      category = "Files";
      icon = "resilio-sync.png";
      description = "File synchronization";
    };
    seafile = {
      category = "Files";
      icon = "seafile.png";
      description = "File sync & share";
    };
    filebrowser = {
      category = "Files";
      icon = "file-alt";
      description = "Web file manager";
    };
    immich = {
      category = "Photos";
      icon = "immich.png";
      description = "Photo/video backup";
    };
    photoprism = {
      category = "Photos";
      icon = "photoprism.png";
      description = "Photo management";
    };
    hass = {
      name = "Home Assistant";
      category = "Home";
      icon = "home-assistant.png";
      description = "Home automation";
    };
    grocy = {
      category = "Home";
      icon = "grocy.png";
      description = "Household management";
    };
    n8n = {
      category = "Home";
      icon = "n8n.png";
      description = "Workflow automation";
    };
    forgejo = {
      category = "Development";
      icon = "forgejo.png";
      description = "Git service";
    };
    code = {
      name = "Code Server";
      category = "Development";
      icon = "visual-studio-code";
      description = "VS Code in browser";
    };
    speedtest = {
      name = "Speedtest Tracker";
      category = "Utilities";
      icon = "tachometer-alt";
      description = "Internet speed tests";
    };
    jellyfin = {
      category = "Media";
      icon = "jellyfin.png";
      description = "Media server";
    }; # Added from storage

    # Cloud Services (Example, add more as needed)
    vault = {
      category = "Security";
      icon = "vault.png";
      description = "Secrets Management";
    }; # Assuming vault runs on cloud
    whoogle = {
      category = "Utilities";
      icon = "search.png";
      description = "Private Search";
    }; # Assuming whoogle runs on cloud
  };

  # Helper function to capitalize the first letter of a string
  capitalizeFirst = str: (lib.toUpper (lib.substring 0 1 str) + lib.substring 1 (-1) str);

  # Process ALL services to include category and final details
  processedServices =
    lib.mapAttrsToList (
      serviceName: serviceConfig: let
        # Check if a mapping exists for this service
        mapping = serviceMappings.${serviceName} or null;
        isMapped = mapping != null;

        # Determine display name
        displayName =
          if isMapped && mapping ? name
          then mapping.name
          else (capitalizeFirst serviceName);

        # Determine category - default to 'Bookmarks' if not mapped
        category =
          if isMapped && mapping ? category
          then mapping.category
          else "Bookmarks";

        # Determine icon - default to 'bookmark' if not mapped
        icon =
          if isMapped && mapping ? icon
          then mapping.icon
          else serviceName;

        # Determine description - default if not mapped
        description =
          if isMapped && mapping ? description
          then mapping.description
          else "Link to ${displayName}";

        # Determine widget - null if not mapped
        widget =
          if isMapped && mapping ? widget
          then mapping.widget
          else null;

        # Determine the correct domain based on the host
        href = "https://${serviceName}.${vars.tsDomain}"; # Correct href generation
      in {
        inherit category displayName icon href description widget;
      }
    )
    config.media.gateway.services; # Iterate over ALL gateway services

  # Group services by category
  groupedServices = lib.groupBy (service: service.category) processedServices;

  # Format the grouped services for homepage configuration
  dynamicServices =
    lib.mapAttrsToList (
      categoryName: servicesInCategory: let
        formattedServices =
          map (service: {
            # Use displayName as the key for the inner map
            ${service.displayName} =
              {
                icon = service.icon;
                href = service.href;
                description = service.description;
              }
              // (lib.optionalAttrs (service.widget != null) {widget = service.widget;}); # Add widget if not null
          })
          servicesInCategory;
        # Use categoryName as the key for the outer map
      in {${categoryName} = formattedServices;}
    )
    groupedServices;
in {
  age.secrets.homepage-env.file = "${self}/secrets/homepage-env.age";

  systemd.services.homepage-dashboard.serviceConfig = {
    SupplementaryGroups = "podman";
  };

  services.homepage-dashboard = {
    enable = true;
    listenPort = 8085;
    environmentFile = config.age.secrets.homepage-env.path;
    docker = {
      "my-docker" = {
        socket = "/run/podman/podman.sock";
      };
    };
    allowedHosts = "home.${vars.domain}";
    widgets = [
      {
        resources = {
          cpu = true;
          memory = true;
          disk = ["/mnt/storage"];
        };
      }
      {
        openmeteo = {
          label = "Rouyn-Noranda";
          timezone = "America/Toronto";
          latitude = "48.2366";
          longitude = "-79.0231";
          units = "metric";
        };
      }
      {
        search = {
          provider = "custom";
          url = "https://www.perplexity.ai/search?q=";
          target = "_blank";
        };
      }
      {datetime = {format = "H:mm";};}
      {greeting = {text_size = "xl";};}
      {
        type = "calendar";
        view = "monthly";
        timezone = "America/Toronto";
        integrations = [
          {
            type = "sonarr";
            service_group = "Management";
            service_name = "Sonarr";
          }
          {
            type = "radarr";
            service_group = "Management";
            service_name = "Radarr";
          }
          # {
          #   type = "lidarr";
          #   service_group = "Management";
          #   service_name = "Lidarr";
          # }
          # You can also add an iCal integration here if desired, for example:
          # {
          #   type = "ical";
          #   # url = "{{HOMEPAGE_VAR_GOOGLE_CALENDAR_URL}}"; # Use a secret for the URL
          #   url = "https://your-public-ical-url.ics"; # Or a public URL directly
          #   name = "Personal Calendar"; # Required
          # }
        ];
      }
    ];
    settings = {
      title = "Storage Dashboard";
      headerStyle = "clean";
      layout = {
        Media = {
          style = "row";
          columns = 3;
        };
        Downloads = {
          style = "row";
          columns = 3;
        };
        Management = {
          style = "row";
          columns = 4;
        };
        System = {
          style = "row";
          columns = 4;
        };
        Files = {
          style = "row";
          columns = 4;
        };
        Photos = {
          style = "row";
          columns = 2;
        };
        Home = {
          style = "row";
          columns = 3;
        };
        Development = {
          style = "row";
          columns = 2;
        };
        Utilities = {
          style = "row";
          columns = 1;
        };
        # Add layout for the new Bookmarks category
        Bookmarks = {
          style = "row";
          columns = 4; # Or your preferred column count
        };
      };
    };
    # Dynamically generated services list replaces the static one
    services = dynamicServices;
  };
}
