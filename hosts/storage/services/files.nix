{
  config,
  pkgs,
  ...
}: let
  vars = config.vars;
in {
  users.users.syncthing.extraGroups = ["nextcloud" "media"];

  services.minio = {
    enable = false;
    dataDir = ["${vars.dataDir}/files/minio"];
  };

  services.syncthing = {
    enable = true;
    guiAddress = "0.0.0.0:8384";
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

  services.nextcloud = {
    enable = true;
    datadir = "${vars.dataDir}/files/Nextcloud";
    hostName = "nextcloud.${vars.domain}";
    maxUploadSize = "10G";
    package = pkgs.nextcloud30;
    appstoreEnable = true;
    autoUpdateApps.enable = true;
    configureRedis = true;
    database.createLocally = true;
    extraApps = {
      inherit (config.services.nextcloud.package.packages.apps) memories calendar tasks mail contacts onlyoffice user_oidc;
    };
    extraAppsEnable = true;
    config = {
      dbtype = "pgsql";
      adminpassFile = "/etc/secrets/nextcloud";
    };
    extraOptions = {
      mail_smtpmode = "sendmail";
      mail_sendmailmode = "pipe";
      trusted_domains = ["storage" "storage.bat-boa.ts.net" "nextcloud.bat-boa.ts.net"];
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

  systemd.services."nextcloud-setup" = {
    requires = ["postgresql.service"];
    after = ["postgresql.service"];
  };

  systemd.services."docker-immich" = {
    requires = ["postgresql.service"];
    after = ["postgresql.service"];
  };
}
