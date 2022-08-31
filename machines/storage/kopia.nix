{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}: let
  backupDir = "/mnt/data/homes";
  credentialsFile = "/etc/secrets/kopia";
in {

  environment.etc = {
    "kopia/repository.config" = {
      text = ''
        {
          "storage": {
            "type": "s3",
            "config": {
              "bucket": "arosenfeld-backup",
              "endpoint": "s3.ca-central-1.wasabisys.com",
              "accessKeyID": "H05UB1VCQRY7G19IBA5X",
              "secretAccessKey": "wIrPzRsgzoM92Igzd9Aibv9fJ9hbCSdzAegekDXA",
              "sessionToken": ""
            }
          },
          "caching": {
            "cacheDirectory": "/var/cache/kopia-arosenfeld-backup",
            "maxCacheSize": 5242880000,
            "maxMetadataCacheSize": 5242880000,
            "maxListCacheDuration": 30
          },
          "hostname": "storage",
          "username": "arosenfeld",
          "description": "Repository in S3: s3.ca-central-1.wasabisys.com arosenfeld-backup",
          "enableActions": false,
          "formatBlobCacheDuration": 900000000000
        }
      '';
      mode = "0644";
    };
  };

  systemd = {
    timers.kopia-backup = {
      enable = false;
      wantedBy = ["timers.target"];
      partOf = ["kopia-backup.service"];
      timerConfig.OnCalendar = "daily";
    };
    services.kopia-backup = let
      kopiaOptions = "--progress --config-file /etc/kopia/repository.config -p $(cat ${credentialsFile})";
    in {
      serviceConfig.Type = "oneshot";
      script = ''
        ${pkgs.kopia}/bin/kopia snapshot create ${kopiaOptions} ${backupDir}
      '';
    };
  };
}
