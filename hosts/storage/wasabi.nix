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
        endpoint = s3.ca-central-1.wasabisys.com
        location_constraint =
        acl =
        server_side_encryption =
        storage_class =
        upload_concurrency = 20
        chunk_size = 50Mi
      '';
      mode = "0644";
    };
  };

  systemd.services.wasabi_mount = {
    enable = true;
    description = "Mount media dir";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      ExecStartPre = "/run/current-system/sw/bin/mkdir -p /mnt/cloud";
      ExecStart = ''
        ${pkgs.rclone}/bin/rclone mount 'wasabi:arosenfeld-cloud/' /mnt/cloud \
          --config=/etc/rclone/rclone.conf \
          --uid 5000 \
          --gid 5000 \
          --umask=0022 \
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
      ExecStop = "/run/wrappers/bin/fusermount -u /mnt/cloud";
      Type = "notify";
      Restart = "always";
      RestartSec = "10s";
      Environment = ["PATH=${pkgs.fuse}/bin:$PATH"];
    };
  };
}
