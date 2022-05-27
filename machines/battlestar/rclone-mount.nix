{
  lib,
  pkgs,
  ...
}:
with lib; {
  environment.systemPackages = [pkgs.rclone];

  environment.etc = {
    "rclone/rclone.conf" = {
      text = ''
        [wasabi]
        type = s3
        provider = Wasabi
        env_auth = false
        access_key_id = H05UB1VCQRY7G19IBA5X
        secret_access_key = wIrPzRsgzoM92Igzd9Aibv9fJ9hbCSdzAegekDXA
        region =
        endpoint = s3.wasabisys.com
        location_constraint =
        acl =
        server_side_encryption =
        storage_class =
      '';
      mode = "0644";
    };
  };

  systemd.services.plex_media = {
    enable = true;
    description = "Mount media dir";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      ExecStartPre = "/run/current-system/sw/bin/mkdir -p /mnt/media";
      ExecStart = ''
        ${pkgs.rclone}/bin/rclone mount 'wasabi:arosenfeld-data/' /mnt/media \
          --config=/etc/rclone/rclone.conf \
          --allow-other \
          --allow-non-empty \
          --log-level=INFO \
          --buffer-size=50M \
          --drive-acknowledge-abuse=true \
          --no-modtime \
          --vfs-cache-mode full \
          --vfs-cache-max-size 20G \
          --vfs-read-chunk-size=32M \
          --vfs-read-chunk-size-limit=256M
      '';
      ExecStop = "/run/wrappers/bin/fusermount -u /mnt/media";
      Type = "notify";
      Restart = "always";
      RestartSec = "10s";
      Environment = ["PATH=${pkgs.fuse}/bin:$PATH"];
    };
  };
}
