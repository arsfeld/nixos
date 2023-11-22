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
  services.netdata.enable = true;

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

  services.mediamtx = {
    enable = true;
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

  security.acme.certs."idm.${vars.domain}" = {
    email = vars.email;
    group = "kanidm";
  };

  #security.pki.certificates = [(builtins.readFile ../../common/certs/cert.crt)];

  services.kanidm = {
    enableServer = true;
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
    appName = "My awesome Gitea server"; # Give the site a name
    domain = "gitea.${vars.domain}";
    rootUrl = "https://gitea.${vars.domain}/";
    httpPort = 3001;
    settings = {
      actions = {
        ENABLED = "true";
      };
    };
  };

  services.minio = {
    enable = true;
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
    hostName = "localhost";
    maxUploadSize = "10G";
    package = pkgs.nextcloud27;
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

  virtualisation.oci-containers.containers = {
    watchtower = {
      image = "containrrr/watchtower";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
    };

    remotely = {
      image = "immybot/remotely:latest";
      ports = ["5000:5000"];
      volumes = [
        "${vars.configDir}/remotely:/remotely-data"
      ];
    };

    homeassistant = {
      volumes = ["/var/lib/home-assistant:/config"];
      environment.TZ = "America/Toronto";
      image = "ghcr.io/home-assistant/home-assistant:stable";
      extraOptions = [
        "--network=host"
        "--privileged"
        "--label"
        "io.containers.autoupdate=image"
      ];
    };

    speedtest = {
      image = "ghcr.io/alexjustesen/speedtest-tracker:latest";
      volumes = ["${vars.configDir}/speedtest:/config"];
      ports = ["8765:80"];
    };

    immich = {
      image = "ghcr.io/imagegenius/immich:latest";
      environment = {
        PUID = vars.puid;
        PGID = vars.pgid;
        TZ = vars.tz;

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
        "${vars.configDir}/plex/env"
      ];
      volumes = [
        "${vars.configDir}/immich:/config"
        "${vars.dataDir}/files/Photos:/photos"
      ];
      extraOptions = ["--add-host" "host.docker.internal:host-gateway"];
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
        PHOTOPRISM_SITE_URL = "https://photoprism.arsfeld.dev/";
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
