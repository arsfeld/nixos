# Garage: a single-node S3 server on loopback, backing mydia's S3 test library.
#
# mydia reads library paths of the form s3://<backend>/<prefix> through its
# own S3 client (Mydia.Storage.S3): scans, ffprobe/ffmpeg via presigned URLs,
# range streaming and imports. This exists to exercise that path against a
# real server. Upload media with any S3 client, e.g. from galactica:
#
#   AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… aws --endpoint-url http://127.0.0.1:3900 \
#     --region garage s3 cp <file> s3://mydia/movies/<Title (Year)>/<file>
#
# The mydia side (storage backend + library env) is in media-apps.nix.
#
# Both ports bind 127.0.0.1 only; mydia is host-networked, so it reaches the
# S3 API on loopback and nothing else can.
{
  config,
  pkgs,
  ...
}: let
  cfg = config.services.garage;
  backend = config.virtualisation.oci-containers.backend;
  bucket = "mydia";
in {
  sops.secrets.garage-env = {};
  sops.secrets.garage-mydia-access-key-id = {};
  sops.secrets.garage-mydia-secret-access-key = {};

  services.garage = {
    enable = true;
    package = pkgs.garage_2;
    environmentFile = config.sops.secrets.garage-env.path; # GARAGE_RPC_SECRET
    settings = {
      db_engine = "sqlite";
      replication_factor = 1;
      rpc_bind_addr = "127.0.0.1:3901";
      rpc_public_addr = "127.0.0.1:3901";
      s3_api = {
        s3_region = "garage";
        api_bind_addr = "127.0.0.1:3900";
      };
    };
  };

  # A fresh node has no layout, and keys and buckets exist only once created.
  # Every step is skipped when already done, so this is safe on each boot.
  systemd.services.garage-bootstrap = {
    description = "Garage layout, key and bucket for mydia";
    after = ["garage.service"];
    requires = ["garage.service"];
    wantedBy = ["multi-user.target"];
    path = [cfg.package pkgs.gnugrep pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = cfg.environmentFile;
      TimeoutStartSec = 120;
    };
    script = ''
      until garage status >/dev/null 2>&1; do sleep 1; done

      if garage layout show | grep -q '^Current cluster layout version: 0$'; then
        garage layout assign -z galactica -c 100G "$(garage node id -q | cut -d@ -f1)"
        garage layout apply --version 1
      fi

      garage key info ${bucket} >/dev/null 2>&1 \
        || garage key import --yes -n ${bucket} \
          "$(cat ${config.sops.secrets.garage-mydia-access-key-id.path})" \
          "$(cat ${config.sops.secrets.garage-mydia-secret-access-key.path})"
      garage bucket info ${bucket} >/dev/null 2>&1 || garage bucket create ${bucket}
      garage bucket allow --read --write --owner ${bucket} --key ${bucket}
    '';
  };

  systemd.services."${backend}-mydia" = {
    wants = ["garage-bootstrap.service"];
    after = ["garage-bootstrap.service"];
  };
}
