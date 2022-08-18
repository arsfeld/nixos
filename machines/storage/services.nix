{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  configDir = "/var/data";
  dataDir = "/mnt/data";
  puid = "5000";
  pgid = "5000";
  tz = "America/Toronto";
in {
  services.netdata.enable = true;

  services.home-assistant = {
    enable = false;
    config = {
      # https://www.home-assistant.io/integrations/default_config/
      default_config = {};
      # https://www.home-assistant.io/integrations/esphome/
      esphome = {};
      # https://www.home-assistant.io/integrations/met/
      met = {};
    };
  };

  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    ensureUsers = [
      {
        name = "filerun";
        ensurePermissions = {
          "filerun.*" = "ALL PRIVILEGES";
        };
      }
    ];
    ensureDatabases = [
      "filerun"
    ];
  };

  services.nextcloud = {
    enable = true;
    datadir = "${dataDir}/files/Nextcloud";
    hostName = "nextcloud.arsfeld.one";
    config = {
      dbtype = "pgsql";
      dbuser = "nextcloud";
      dbhost = "/run/postgresql"; # nextcloud will add /.s.PGSQL.5432 by itself
      dbname = "nextcloud";
      adminpassFile = "/etc/secrets/nextcloud";
      adminuser = "root";
      extraTrustedDomains = ["storage"];
      trustedProxies = ["100.66.83.36"];
      overwriteProtocol = "https";
    };
  };

  services.postgresql = {
    enable = true;
    ensureDatabases = ["nextcloud"];
    ensureUsers = [
      {
        name = "nextcloud";
        ensurePermissions."DATABASE nextcloud" = "ALL PRIVILEGES";
      }
    ];
  };

  systemd.services."nextcloud-setup" = {
    requires = ["postgresql.service"];
    after = ["postgresql.service"];
  };

  virtualisation.oci-containers.containers = {
    watchtower = {
      image = "containrrr/watchtower";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
    };

    plex = {
      image = "lscr.io/linuxserver/plex";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
        VERSION = "latest";
      };
      environmentFiles = [
        "${configDir}/plex/env"
      ];
      volumes = [
        "${configDir}/plex:/config"
        "${dataDir}/media:/data"
      ];
      extraOptions = [
        "--device"
        "/dev/dri:/dev/dri"
        "--network=host"
      ];
    };

    qflood = {
      image = "cr.hotio.dev/hotio/qflood";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
        FLOOD_AUTH = "false";
        VPN_LAN_NETWORK = "10.0.0.0/24,100.64.0.0/10";
        VPN_ENABLED = "true";
      };
      ports = ["8080:8080/tcp" "3000:3000"];
      volumes = [
        "${configDir}/qflood:/config"
        "${dataDir}/media:/media"
        "${dataDir}/files:/files"
      ];
      extraOptions = [
        "--cap-add"
        "NET_ADMIN"
        "--sysctl"
        "net.ipv4.conf.all.src_valid_mark=1"
        "--sysctl"
        "net.ipv6.conf.all.disable_ipv6=1"
      ];
    };

    # homeassistant = {
    #   volumes = [ "home-assistant:/config" ];
    #   environment.TZ = "America/Toronto";
    #   image = "ghcr.io/home-assistant/home-assistant:stable";
    #   extraOptions = [
    #     "--network=host"
    #   ];
    # };

    scrutiny = {
      image = "ghcr.io/analogj/scrutiny:master-omnibus";
      ports = ["8888:8080" "8086:8086"];
      volumes = [
        "${configDir}/scrutiny/config:/opt/scrutiny/config"
        "${configDir}/scrutiny/influxdb:/opt/scrutiny/influxdb"
        "/run/udev:/run/udev:ro"
      ];
      extraOptions = [
        "--cap-add=SYS_RAWIO"
        "--device=/dev/sda"
        "--device=/dev/sdb"
        "--device=/dev/sdc"
        "--device=/dev/sdd"
        "--device=/dev/sde"
        "--device=/dev/sdf"
        "--device=/dev/sdg"
        "--device=/dev/sdh"
        "--device=/dev/sdi"
      ];
    };

    syncthing = {
      image = "ghcr.io/linuxserver/syncthing";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = ["8384:8384" "22000:22000" "21027:21027/udp"];
      volumes = [
        "${configDir}/syncthing:/config"
        "${dataDir}/files:/data"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    photoprism = {
      image = "photoprism/photoprism:latest";
      ports = ["2342:2342"];
      environment = {
        PHOTOPRISM_SITE_URL = "https://photoprism.arsfeld.dev/";
        PHOTOPRISM_UPLOAD_NSFW = "true";
        PHOTOPRISM_ADMIN_PASSWORD = "password";
      };
      volumes = [
        "${configDir}/photoprism:/photoprism/storage"
        "/home/arosenfeld/Pictures:/photoprism/originals"
      ];
      extraOptions = [
        "--security-opt"
        "seccomp=unconfined"
        "--security-opt"
        "apparmor=unconfined"
      ];
    };

    stash = {
      image = "stashapp/stash:latest";
      ports = ["9999:9999"];
      volumes = [
        "${configDir}/stash:/root/.stash"
        "${dataDir}/media:/data"
      ];
    };

    filestash = {
      image = "machines/filestash";
      ports = ["8334:8334"];
      volumes = [
        "${configDir}/filestash:/app/data/state"
        "${dataDir}/media:/mnt/data/media"
        "${dataDir}/files:/mnt/data/files"
      ];
    };

    nzbget = {
      image = "ghcr.io/linuxserver/nzbget";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = ["6789:6789"];
      volumes = [
        "${configDir}/nzbget:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    sabnzbd = {
      image = "ghcr.io/linuxserver/sabnzbd";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = ["8880:8080"];
      volumes = [
        "${configDir}/sabnzbd:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    nzbhydra2 = {
      image = "ghcr.io/linuxserver/nzbhydra2";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = ["5076:5076"];
      volumes = [
        "${configDir}/nzbhydra2:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    jackett = {
      image = "ghcr.io/linuxserver/jackett";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = ["9117:9117"];
      volumes = [
        "${configDir}/jackett:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    sonarr = {
      image = "ghcr.io/linuxserver/sonarr";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = ["8989:8989"];
      volumes = [
        "${configDir}/sonarr:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    radarr = {
      image = "ghcr.io/linuxserver/radarr";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = ["7878:7878"];
      volumes = [
        "${configDir}/radarr:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    prowlarr = {
      image = "ghcr.io/linuxserver/prowlarr:develop";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = ["9696:9696"];
      volumes = [
        "${configDir}/prowlarr:/config"
        "${dataDir}/files:/files"
        "${dataDir}/media:/media"
      ];
    };

    "headscale-ui" = {
      image = "ghcr.io/gurucomputing/headscale-ui:latest";
      ports = [
        "9899:80"
      ];
    };

    "filerun" = {
      image = "filerun/filerun";
      environment = {
        "FR_DB_HOST" = "localhost";
        "FR_DB_PORT" = "3306";
        "FR_DB_NAME" = "filerun";
        "FR_DB_USER" = "filerun";
      };
      ports = ["6000:80"];
      volumes = [
        "${configDir}/filerun:/var/www/html"
        "${dataDir}/files/Filerun:/user-files"
      ];
      extraOptions = [
        "--add-host"
        "host.docker.internal:host-gateway"
      ];
    };
  };
}
