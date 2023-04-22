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
  user = "media";
  group = "media";
  tz = "America/Toronto";
  email = "arsfeld@gmail.com";
  domain = "arsfeld.one";
  ports = {
    qbittorrent = "8080";
    immich = "15777";
  };
in {
  services.netdata.enable = true;

  #users.users.vault.extraGroups = ["acme" "caddy"];

  services.vault = {
    enable = false;
    storageBackend = "file";
    address = "0.0.0.0:8200";
    extraConfig = "ui = true";
    package = pkgs.vault-bin;
    tlsCertFile = "/var/lib/acme/arsfeld.one/cert.pem";
    tlsKeyFile = "/var/lib/acme/arsfeld.one/key.pem";
  };

  #users.users.kanidm.extraGroups = ["acme"];

  security.acme.certs."idm.${domain}" = {
    email = email;
    group = "kanidm";
  };

  #security.pki.certificates = [(builtins.readFile ../../common/certs/cert.crt)];

  services.kanidm = {
    enableServer = true;
    serverSettings = {
      origin = "https://idm.${domain}";
      domain = domain;
      # tls_chain = "/var/lib/acme/idm.${domain}/cert.pem";
      # tls_key = "/var/lib/acme/idm.${domain}/key.pem";
      tls_chain = ../../common/certs/cert.crt;
      tls_key = ../../common/certs/cert.key;
      bindaddress = "0.0.0.0:8443";
    };
    enableClient = true;
    clientSettings = {
      uri = "https://idm.${domain}";
      verify_ca = true;
      verify_hostnames = true;
    };
  };

  age.secrets.keycloak-pass = {
    file = ../../secrets/keycloak-pass.age;
  };

  services.keycloak = {
    enable = false;

    database = {
      type = "postgresql";
      createLocally = true;

      username = "keycloak";
      passwordFile = config.age.secrets.keycloak-pass.path;
    };

    settings = {
      hostname = "cloak.rosenfeld.one";
      #http-relative-path = "/cloak";
      http-port = 38080;
      proxy = "passthrough";
      http-enabled = true;
    };
  };

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

  services.grafana = {
    enable = true;
    domain = "grafana.${domain}";
    port = 2345;
    addr = "0.0.0.0";
  };

  services.prometheus = {
    enable = true;
    port = 8001;

    exporters = {
      node = {
        enable = true;
        enabledCollectors = ["systemd"];
        port = 8002;
      };
    };

    scrapeConfigs = [
      {
        job_name = "storage";
        static_configs = [
          {
            targets = ["127.0.0.1:${toString config.services.prometheus.exporters.node.port}"];
          }
        ];
      }
    ];
  };

  services.loki = {
    enable = true;
    configFile = ./files/loki-local-config.yaml;
  };

  systemd.services.promtail = {
    description = "Promtail service for Loki";
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      ExecStart = ''
        ${pkgs.grafana-loki}/bin/promtail --config.file ${./files/promtail.yaml}
      '';
    };
  };

  services.code-server = {
    enable = true;
    user = "arosenfeld";
    host = "0.0.0.0";
  };

  services.gitea = {
    enable = true;
    appName = "My awesome Gitea server"; # Give the site a name
    domain = "gitea.${domain}";
    rootUrl = "https://gitea.${domain}/";
    httpPort = 3001;
    settings = {
      actions = {
        ENABLED = "true";
      };
    };
  };

  services.minio = {
    enable = true;
    dataDir = ["${dataDir}/files/minio"];
  };

  services.seafile = {
    enable = false;
    adminEmail = "arsfeld@gmail.com";
    initialAdminPassword = "password";
    seafileSettings = {
      fileserver.host = "0.0.0.0";
    };
    ccnetSettings.General.SERVICE_URL = "https://seafile.${domain}";
  };

  services.restic.server = {
    enable = true;
    appendOnly = true;
    extraFlags = ["--no-auth"];
  };

  users.users.caddy.extraGroups = ["acme"];

  security.acme = {
    acceptTerms = true;
  };

  services.caddy = {
    enable = true;
  };

  services.tailscale.permitCertUid = "caddy";

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
    hostName = "localhost";
    maxUploadSize = "10G";
    package = pkgs.nextcloud26;
    config = {
      dbtype = "pgsql";
      dbuser = "nextcloud";
      dbhost = "/run/postgresql"; # nextcloud will add /.s.PGSQL.5432 by itself
      dbname = "nextcloud";
      adminpassFile = "/etc/secrets/nextcloud";
      adminuser = "root";
      extraTrustedDomains = ["nextcloud.arsfeld.one" "storage"];
      trustedProxies = ["100.66.83.36"];
      #overwriteProtocol = "https";
    };
    extraOptions = {
      mail_smtpmode = "sendmail";
      mail_sendmailmode = "pipe";
    };
  };

  services.nginx.defaultHTTPListenPort = 8099;

  services.jellyfin = {
    enable = true;
    user = user;
    group = group;
  };

  services.postgresql = {
    enable = true;
    ensureDatabases = ["nextcloud" "immich"];
    enableTCPIP = true;
    ensureUsers = [
      {
        name = "nextcloud";
        ensurePermissions."DATABASE nextcloud" = "ALL PRIVILEGES";
      }
      {
        name = "immich";
        ensurePermissions."DATABASE immich" = "ALL PRIVILEGES";
      }
    ];
    authentication = lib.mkForce ''
      # Generated file; do not edit!
      # TYPE  DATABASE        USER            ADDRESS                 METHOD
      local   all             all                                     trust
      host    all             all             172.17.0.0/16           trust
      host    all             all             127.0.0.1/32            trust
      host    all             all             ::1/128                 trust
    '';
  };

  systemd.services."nextcloud-setup" = {
    requires = ["postgresql.service"];
    after = ["postgresql.service"];
  };

  services.redis.servers.immich = {
    enable = true;
    port = 60609;
    bind = "0.0.0.0";
    settings = {
      "protected-mode" = "no";
    };
  };

  services.bazarr = {
    enable = true;
    user = user;
    group = group;
  };

  services.borgbackup.repos.micro = {
    authorizedKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO2ARxC0ATSCx+aqf66IkUOOwIw6CGwsH47uYXj1+P2U root@micro"];
    allowSubRepos = true;
  };

  virtualisation.oci-containers.containers = {
    watchtower = {
      image = "containrrr/watchtower";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
    };

    speedtest = {
      image = "henrywhitaker3/speedtest-tracker";
      volumes = ["speedtest:/config"];
      environment.OOKLA_EULA_GDPR = "true";
      ports = ["8765:80"];
    };

    immich = {
      image = "ghcr.io/imagegenius/immich:latest";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;

        DB_HOSTNAME = "host.docker.internal";
        DB_USERNAME = "immich";
        DB_PASSWORD = "immich";
        DB_DATABASE_NAME = "immich";
        REDIS_HOSTNAME = "host.docker.internal";
        JWT_SECRET = "somelongrandomstring";
        DB_PORT = "5432";
        REDIS_PORT = "60609";
      };
      ports = ["${ports.immich}:8080/tcp"];
      environmentFiles = [
        "${configDir}/plex/env"
      ];
      volumes = [
        "${configDir}/immich:/config"
        "${dataDir}/files/Photos:/photos"
      ];
      extraOptions = ["--add-host" "host.docker.internal:host-gateway"];
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

    jf-vue = {
      image = "jellyfin/jellyfin-vue:unstable";
      environment = {
        DEFAULT_SERVERS = "https://jellyfin.${domain}";
      };
      ports = ["3831:80"];
    };

    # gluetun = {
    #   image = "ghcr.io/qdm12/gluetun";
    #   environment = {
    #     VPN_SERVICE_PROVIDER = "MULLVAD";
    #     VPN_TYPE = "openvpn";
    #     OPENVPN_USER = "4493235546215778";
    #     OPENVPN_PASSWORD = "m";
    #   };
    #   ports = ["8080:8080"];
    #   volumes = [
    #     "/dev/net/tun:/dev/net/tun"
    #     "${configDir}/gluetun:/gluetun"
    #   ];
    #   extraOptions = [
    #     "--cap-add"
    #     "NET_ADMIN"
    #     "--dns"
    #     "8.8.8.8"
    #     "--dns"
    #     "8.8.4.4"
    #   ];
    # };

    # qbittorrent = {
    #   image = "lscr.io/linuxserver/qbittorrent:latest";
    #   environment = {
    #     PUID = puid;
    #     PGID = pgid;
    #     TZ = tz;
    #     WEBUI_PORT = "8080";
    #   };
    #   volumes = [
    #     "${configDir}/qbittorrent:/config"
    #     "${dataDir}/media:/media"
    #     "${dataDir}/files:/files"
    #   ];
    #   extraOptions = [
    #     "--network"
    #     "container:gluetun"
    #   ];
    # };

    qflood = {
      image = "cr.hotio.dev/hotio/qflood";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
        FLOOD_AUTH = "false";
        VPN_LAN_NETWORK = "192.168.31.0/24,100.64.0.0/10";
        VPN_ENABLED = "true";
        VPN_IP_CHECK_DELAY = "15";
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
      environment = {
        COLLECTOR_CRON_SCHEDULE = "0 0 * * 7";
      };
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

    # syncthing = {
    #   image = "ghcr.io/linuxserver/syncthing";
    #   environment = {
    #     PUID = puid;
    #     PGID = pgid;
    #     TZ = tz;
    #   };
    #   ports = ["8384:8384" "22000:22000" "21027:21027/udp"];
    #   volumes = [
    #     "${configDir}/syncthing:/config"
    #     "${dataDir}/files:/data"
    #     "${dataDir}/files:/files"
    #     "${dataDir}/media:/media"
    #   ];
    # };

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

    whisparr = {
      image = "cr.hotio.dev/hotio/whisparr";
      environment = {
        PUID = puid;
        PGID = pgid;
        TZ = tz;
      };
      ports = ["6969:6969"];
      volumes = [
        "${configDir}/whisparr:/config"
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

    flaresolverr = {
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      ports = ["8191:8191"];
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
