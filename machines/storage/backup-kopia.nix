{pkgs, ...}: let
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
              "endpoint": "backup.penguin-gecko.ts.net",
              "accessKeyID": "KZsHDbA49ZBLAGJA",
              "secretAccessKey": "eduODznW5ckv9xEortRa2rgsZJ3XCHZi",
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
          "description": "Repository in Servarica arosenfeld-backup",
          "enableActions": false,
          "formatBlobCacheDuration": 900000000000
        }
      '';
      mode = "0644";
    };
  };

  systemd = {
    timers.kopia-backup = {
      enable = true;
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
