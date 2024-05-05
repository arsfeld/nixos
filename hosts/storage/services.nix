{
  lib,
  config,
  pkgs,
  ...
}: let
  vars = config.vars;
  ports = {
    qbittorrent = "8080";
    immich = "15777";
  };
  plex-trakt-sync = {interactive ? false}: ''    ${pkgs.docker}/bin/docker run ${
      if interactive
      then "-it"
      else ""
    } --rm \
            -v ${vars.configDir}/plex-track-sync:/app/config \
            ghcr.io/taxel/plextraktsync'';
in {
  age.secrets.attic-token.file = ../../secrets/attic-token.age;

  services.netdata = {
    enable = true;
    configDir = {
      "go.d/prometheus.conf" = pkgs.writeText "go.d/prometheus.conf" ''
        jobs:
        - name: blocky-dns
          url: http://127.0.0.1:4000/metrics
      '';
    };
  };

  services.redis.servers.blocky.slaveOf = {
    ip = "100.66.38.77";
    port = 6378;
  };

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "plex-trakt-sync" "${(plex-trakt-sync {interactive = true;})} \"$@\"")
  ];

  systemd = {
    timers.plex-trakt-sync = {
      wantedBy = ["timers.target"];
      partOf = ["simple-timer.service"];
      timerConfig.OnCalendar = "weekly";
    };
    services.plex-trakt-sync = {
      serviceConfig.Type = "oneshot";
      script = "${(plex-trakt-sync {})} sync";
    };
  };

  users.users.syncthing.extraGroups = ["nextcloud" "media"];

  services.syncthing = {
    enable = true;
    guiAddress = "0.0.0.0:8384";
  };

  services.mediamtx = {
    enable = false;
    settings = {
      paths = {
        backyard = {
          source = "rtsp://Xs35gu17EcpZ:Fk5pWwyEC9cv@192.168.1.9/live0";
        };
        parking = {
          source = "rtsp://Xs35gu17EcpZ:Fk5pWwyEC9cv@192.168.1.9/live1";
        };
        driveway = {
          source = "rtsp://Qg1iB00ay1ep:Tf7RLVkG6Tqb@192.168.1.243/live0";
        };
        all = {
          runOnReady = ''
            ${pkgs.ffmpeg}/bin/ffmpeg -i rtsp://localhost:$RTSP_PORT/$MTX_PATH
            -c copy
            -f segment -strftime 1 -segment_time 60 -segment_format mpegts ${vars.dataDir}/files/Camera/saved_%Y-%m-%d_%H-%M-%S.ts
          '';
          runOnReadyRestart = true;
        };
      };
    };
  };

  services.adguardhome = {
    enable = false;
    settings = {
      users = [
        {
          name = "admin";
          password = "$2a$10$ZqHeXubJoB7II0u/39Byiu4McdkjCoqurctIlMikm4kyILQvEevEO";
        }
      ];
      bind_port = 3000;
      dns = {
        bind_hosts = ["0.0.0.0"];
        port = 53;
        rewrites = [
          {
            domain = "*.arsfeld.one";
            answer = "100.118.254.136";
          }
        ];
        upstream_dns = ["1.1.1.1" "1.0.0.1"];
      };
    };
  };

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

  # security.acme.certs."idm.${vars.domain}" = {
  #   email = vars.email;
  #   group = "kanidm";
  # };

  #security.pki.certificates = [(builtins.readFile ../../common/certs/cert.crt)];

  services.kanidm = {
    enableServer = false;
    serverSettings = {
      origin = "https://idm.${vars.domain}";
      domain = vars.domain;
      # tls_chain = "/var/lib/acme/idm.${vars.domain}/cert.pem";
      # tls_key = "/var/lib/acme/idm.${vars.domain}/key.pem";
      tls_chain = ../../common/certs/cert.crt;
      tls_key = ../../common/certs/cert.key;
      bindaddress = "0.0.0.0:8443";
    };
    enableClient = true;
    clientSettings = {
      uri = "https://idm.${vars.domain}";
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

  services.openvscode-server = {
    enable = true;
    user = "arosenfeld";
    host = "0.0.0.0";
    port = 3434;
    withoutConnectionToken = true;
  };

  services.gitea = {
    enable = true;
    appName = "My awesome Gitea server";
    settings = {
      server = {
        ROOT_URL = "https://gitea.${vars.domain}/";
        HTTP_PORT = 3001;
        DOMAIN = "gitea.${vars.domain}";
      };
      actions = {
        ENABLED = "true";
      };
    };
  };

  services.minio = {
    enable = false;
    dataDir = ["${vars.dataDir}/files/minio"];
  };

  services.seafile = {
    enable = false;
    adminEmail = vars.email;
    initialAdminPassword = "password";
    seafileSettings = {
      fileserver.host = "0.0.0.0";
    };
    ccnetSettings.General.SERVICE_URL = "https://seafile.${vars.domain}";
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
    datadir = "${vars.dataDir}/files/Nextcloud";
    hostName = "nextcloud.${vars.domain}";
    maxUploadSize = "10G";
    package = pkgs.nextcloud28;
    appstoreEnable = true;
    autoUpdateApps.enable = true;
    configureRedis = true;
    database.createLocally = true;
    extraApps = {
      inherit (config.services.nextcloud.package.packages.apps) memories contacts calendar tasks;
    };
    extraAppsEnable = true;
    config = {
      dbtype = "pgsql";
      adminpassFile = "/etc/secrets/nextcloud";
    };
    extraOptions = {
      mail_smtpmode = "sendmail";
      mail_sendmailmode = "pipe";
      trusted_domains = ["storage" "storage.bat-boa.ts.net"];
      trusted_proxies = ["100.66.83.36"];
      overwriteprotocol = "https";
    };
    phpOptions = {
      "opcache.interned_strings_buffer" = "23";
    };
    extraOptions.enabledPreviewProviders = [
      "OC\\Preview\\BMP"
      "OC\\Preview\\GIF"
      "OC\\Preview\\JPEG"
      "OC\\Preview\\Krita"
      "OC\\Preview\\MarkDown"
      "OC\\Preview\\MP3"
      "OC\\Preview\\OpenDocument"
      "OC\\Preview\\PNG"
      "OC\\Preview\\TXT"
      "OC\\Preview\\XBitmap"
      "OC\\Preview\\HEIC"
    ];
  };

  services.nginx.defaultHTTPListenPort = 8099;

  services.postgresql = {
    enable = true;
    ensureDatabases = ["nextcloud" "immich"];
    enableTCPIP = true;
    package = pkgs.postgresql_15;
    extraPlugins = with pkgs.postgresql_15.pkgs; [pgvecto-rs pgvector];
    ensureUsers = [
      {
        name = "nextcloud";
        ensureClauses = {
          createrole = true;
          createdb = true;
        };
        ensureDBOwnership = true;
      }
      {
        name = "immich";
        ensureClauses = {
          createrole = true;
          createdb = true;
        };
        ensureDBOwnership = true;
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

  services.postgresqlBackup = {
    enable = true;
    compression = "zstd";
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

  virtualisation.oci-containers.containers = let
    immich-options = {
      image = "ghcr.io/immich-app/immich-server:release";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;

        DB_HOSTNAME = "immich-db";
        DB_USERNAME = "immich";
        DB_PASSWORD = "immich";
        DB_DATABASE_NAME = "immich";
        REDIS_HOSTNAME = "host.docker.internal";
        JWT_SECRET = "somelongrandomstring";
        DB_PORT = "5432";
        REDIS_PORT = "60609";
      };
      volumes = [
        "${vars.dataDir}/files/Photos:/usr/src/app/upload"
        "${vars.dataDir}/files/Takeout:/takeout"
      ];
      cmd = ["start.sh" "immich"];
      extraOptions = [
        "--add-host=host.docker.internal:host-gateway"
        "--link=immich-db"
        "--link=immich-ml"
        "--device=/dev/dri"
      ];
    };
  in {
    immich-server =
      immich-options
      // {
        ports = ["${ports.immich}:3001"];
        cmd = ["start.sh" "immich"];
      };

    immich-microservices =
      immich-options
      // {
        cmd = ["start.sh" "microservices"];
        extraOptions = [
          "--add-host=host.docker.internal:host-gateway"
          "--link=immich-db"
          "--link=immich-ml"
          "--device=/dev/dri"
        ];
      };

    immich-ml = {
      image = "ghcr.io/immich-app/immich-machine-learning:release";
      volumes = [
        "${vars.configDir}/immich/model-cache:/cache"
      ];
      extraOptions = ["--net-alias=immich-ml"];
    };

    immich-db = {
      image = "registry.hub.docker.com/tensorchord/pgvecto-rs:pg14-v0.2.0";
      environment = {
        POSTGRES_PASSWORD = "immich";
        POSTGRES_USER = "immich";
        POSTGRES_DB = "immich";
      };
      volumes = [
        "${vars.configDir}/immich/db:/var/lib/postgresql/data"
      ];
      extraOptions = ["--net-alias=immich-db"];
    };

    watchtower = {
      image = "containrrr/watchtower";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
    };

    # remotely = {
    #   image = "immybot/remotely:latest";
    #   ports = ["5000:5000"];
    #   volumes = [
    #     "${vars.configDir}/remotely:/app/AppData"
    #   ];
    #   environment = {
    #     Remotely_ApplicationOptions__DbProvider = "SQLite";
    #     Remotely_ConnectionStrings__SQLite = "Data Source=/app/AppData/Remotely.db";
    #   };
    # };

    # homeassistant = {
    #   volumes = ["/var/lib/home-assistant:/config"];
    #   environment.TZ = "America/Toronto";
    #   image = "ghcr.io/home-assistant/home-assistant:stable";
    #   extraOptions = [
    #     "--network=host"
    #     "--privileged"
    #     "--label"
    #     "io.containers.autoupdate=image"
    #   ];
    # };

    speedtest = {
      image = "lscr.io/linuxserver/speedtest-tracker:latest";
      volumes = ["${vars.configDir}/speedtest:/config"];
      ports = ["8765:80"];
      environment = {
        "APP_KEY" = "base64:MGxwY3Y1OHZpMnJwN2s2dGtkdnJ6dm40ODEwd3J4eGI=";
        "DB_CONNECTION" = "sqlite";
      };
    };

    netbootxyz = {
      image = "lscr.io/linuxserver/netbootxyz:latest";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;
        # - MENU_VERSION=1.9.9 #optional
        # - PORT_RANGE=30000:30010 #optional
        # - SUBFOLDER=/ #optional
      };
      volumes = [
        "${vars.configDir}/netbootxyz:/config"
        "${vars.dataDir}/files/ISO:/assets"
      ];
      ports = [
        "3000:3000"
        "69:69/udp"
        "8080:80"
      ];
    };

    scrutiny = {
      image = "ghcr.io/analogj/scrutiny:master-omnibus";
      ports = ["9998:8080" "8086:8086"];
      environment = {
        COLLECTOR_CRON_SCHEDULE = "0 0 * * 7";
      };
      volumes = [
        "${vars.configDir}/scrutiny/config:/opt/scrutiny/config"
        "${vars.configDir}/scrutiny/influxdb:/opt/scrutiny/influxdb"
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

    photoprism = {
      image = "photoprism/photoprism:latest";
      ports = ["2342:2342"];
      environment = {
        PHOTOPRISM_SITE_URL = "https://photoprism.arsfeld.one/";
        PHOTOPRISM_UPLOAD_NSFW = "true";
        PHOTOPRISM_ADMIN_PASSWORD = "password";
      };
      volumes = [
        "${vars.configDir}/photoprism:/photoprism/storage"
        "/home/arosenfeld/Pictures:/photoprism/originals"
      ];
      extraOptions = [
        "--security-opt"
        "seccomp=unconfined"
        "--security-opt"
        "apparmor=unconfined"
      ];
    };

    filestash = {
      image = "machines/filestash";
      ports = ["8334:8334"];
      volumes = [
        "${vars.configDir}/filestash:/app/data/state"
        "${vars.dataDir}/media:/mnt/data/media"
        "${vars.dataDir}/files:/mnt/data/files"
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
        "${vars.configDir}/filerun:/var/www/html"
        "${vars.dataDir}/files/Filerun:/user-files"
      ];
      extraOptions = [
        "--add-host"
        "host.docker.internal:host-gateway"
      ];
    };
  };
}
