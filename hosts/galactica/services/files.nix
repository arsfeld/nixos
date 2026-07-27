{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  vars = config.media.config;
  # Use nextcloud31 from nixpkgs-unstable to get the latest version
  # This prevents downgrade issues when stable has an older version
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config = pkgs.config;
  };

  # Syncthing device ID of the Pixel 3 XL that forwards staged photos to Google
  # Photos. This is a fresh Syncthing install (2026-07-26); an older, now-stale
  # "Pixel 3 XL" device (SZQ2JJJ…) still exists in the GUI config attached to the
  # legacy `photosync` folder, and is not this one.
  pixelDeviceId = "AHQ2BZC-LKGTOWG-PGKTKBV-6INI2Z6-O4RFQ5Q-ZN32AX3-R6KDSF6-WRHPNAT";
in {
  media.services.syncthing = {port = 8384;};
  media.services.nextcloud = {
    port = 8099;
    bypassAuth = true;
  };

  media.services.filebrowser = {
    port = 8080;
    image = "filebrowser/filebrowser:s6";
    container = {
      exposePort = 38080;
      configDir = null;
      volumes = [
        "${vars.dataDir}/files:/srv"
        "${vars.configDir}/filebrowser/filebrowser.db:/database/filebrowser.db"
        "${vars.configDir}/filebrowser/settings.json:/config/settings.json"
      ];
    };
  };

  users.users.syncthing.extraGroups = ["nextcloud" "media"];

  services.minio = {
    enable = false;
    dataDir = ["${vars.dataDir}/files/minio"];
  };

  services.syncthing = {
    enable = true;
    guiAddress = "0.0.0.0:8384";
    group = "media";

    # Every other folder and device on this host was created through the GUI.
    # Both of these default to true, which would DELETE anything Nix does not
    # declare — five folders (default, photos, photosync, and two more) and six
    # devices. Keep the declarative config strictly additive.
    overrideFolders = false;
    overrideDevices = false;

    settings = {
      devices.pixel3xl = {
        id = pixelDeviceId;
        name = "Pixel 3 XL (photo stage)";
        # galactica and the Pixel sit behind different routers that both use
        # 192.168.18.0/24, so there is no route between the sites and relaying is
        # the only fallback. Tailscale gives a direct path; keep `dynamic` after
        # it so discovery still works if the tailnet is down.
        addresses = ["tcp://pixel-3-xl.bat-boa.ts.net:22000" "dynamic"];
      };

      # sendonly here plus receiveonly on the phone means no deletion can travel
      # backwards into the staging directory — and nothing can reach Immich from
      # there anyway, since staged files are only hardlinks and reflinks.
      folders.pixel-photo-stage = {
        id = "pixel-photo-stage";
        label = "Pixel Photo Stage";
        path = config.constellation.immichPixelSync.stagingDirectory;
        type = "sendonly";
        devices = ["pixel3xl"];
      };
    };
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
    package = pkgs-unstable.nextcloud32;
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
      trusted_domains = ["galactica" "galactica.bat-boa.ts.net" "nextcloud.bat-boa.ts.net" "nextcloud.arsfeld.one"];
      trusted_proxies = ["100.66.83.36"];
      overwriteprotocol = "https";
      overwritehost = "nextcloud.arsfeld.one";
      # Allow connections to Tailscale IPs for OIDC provider (Authelia)
      allow_local_remote_servers = true;
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
}
