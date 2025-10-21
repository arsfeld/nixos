{
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;
in {
  users.users.syncthing.extraGroups = ["nextcloud" "media"];

  services.minio = {
    enable = false;
    dataDir = ["${vars.dataDir}/files/minio"];
  };

  services.syncthing = {
    enable = true;
    guiAddress = "0.0.0.0:8384";
    group = "media";
  };

  services.webdav-server-rs = {
    enable = true;
    settings = {
      server.listen = ["0.0.0.0:4918" "[::]:4918"];
      accounts = {
        auth-type = "htpasswd.default";
        acct-type = "unix";
      };
      htpasswd.default = {
        htpasswd = pkgs.writeText "htpasswd" "arosenfeld:$2y$10$vVSREtogLxRBBRcKKcwNq.0mJTMeoQlKUnzI7Lmf4N7I.o7JKI/4u";
      };
      location = [
        {
          route = ["/public/*path"];
          directory = "/mnt/data/files";
          handler = "filesystem";
          methods = ["webdav-ro"];
          autoindex = true;
          auth = "false";
        }
        {
          route = ["/photosync/*path"];
          directory = "/mnt/data/files/PhotoSync";
          handler = "filesystem";
          methods = ["webdav-rw"];
          autoindex = true;
          auth = "true";
          setuid = true;
        }
      ];
    };
  };

  services.tsnsrv.services.webdav = {
    toURL = "http://127.0.0.1:4918";
    funnel = false;
  };

  virtualisation.oci-containers.containers = {
    filebrowser = {
      image = "filebrowser/filebrowser:s6";
      volumes = [
        "${vars.dataDir}/files:/srv"
        "${vars.configDir}/filebrowser/filebrowser.db:/database/filebrowser.db"
        "${vars.configDir}/filebrowser/settings.json:/config/settings.json"
      ];
      environment = {
        PUID = toString vars.puid;
        PGID = toString vars.pgid;
      };
      ports = ["38080:8080"];
    };
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

  # Fix tmpfiles ownership issue by explicitly creating directories with correct ownership
  # This prevents systemd-tmpfiles from creating directories with incorrect ownership during activation
  systemd.tmpfiles.rules = [
    "d /var/lib/nextcloud 0750 nextcloud nextcloud -"
    "d /var/lib/nextcloud/data 0750 nextcloud nextcloud -"
    "d /var/lib/nextcloud/data/config 0750 nextcloud nextcloud -"
  ];

  services.nextcloud = {
    enable = true;
    datadir = "/var/lib/nextcloud/data";
    hostName = "nextcloud.${vars.domain}";
    maxUploadSize = "10G";
    package = pkgs.nextcloud31;
    appstoreEnable = false; # Disable to avoid write permission issues with NixOS-managed apps
    autoUpdateApps.enable = false;
    configureRedis = true;
    database.createLocally = true;
    extraApps = {
      inherit (config.services.nextcloud.package.packages.apps) memories calendar tasks mail contacts onlyoffice user_oidc;
    };
    extraAppsEnable = true; # Enable NixOS-managed apps
    config = {
      dbtype = "pgsql";
      adminpassFile = "/etc/secrets/nextcloud";
    };
    settings = {
      mail_smtpmode = "sendmail";
      mail_sendmailmode = "pipe";
      trusted_domains = ["storage" "storage.bat-boa.ts.net" "nextcloud.bat-boa.ts.net" "nextcloud.arsfeld.one"];
      trusted_proxies = ["100.66.83.36"];
      overwriteprotocol = "https";
      # OIDC configuration for user_oidc app
      user_oidc = {
        default_token_endpoint_auth_method = "client_secret_post";
      };
    };
    phpOptions = {
      "opcache.interned_strings_buffer" = "23";
    };
    settings.enabledPreviewProviders = [
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

  systemd.services."nextcloud-setup" = {
    requires = ["postgresql.service"];
    after = ["postgresql.service"];
  };

  systemd.services."podman-immich" = {
    requires = ["postgresql.service"];
    after = ["postgresql.service"];
  };
}
