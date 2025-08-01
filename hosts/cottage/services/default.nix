{
  config,
  pkgs,
  self,
  ...
}: let
  vars = config.media.config;
in {
  imports = [
  ];

  # Age secret for MinIO credentials
  age.secrets."minio-credentials" = {
    file = "${self}/secrets/minio-credentials.age";
    owner = "minio";
    group = "minio";
  };

  # Enable and configure MinIO as S3-compatible backup destination
  services.minio = {
    enable = true;
    rootCredentialsFile = config.age.secrets.minio-credentials.path;
    dataDir = ["/mnt/storage/backups/minio"];
    listenAddress = ":9000";
    consoleAddress = ":9001";
    region = "auto";
  };

  # Add MinIO to the media gateway when media is enabled
  # media.gateway.services.minio = {
  #   host = "cottage";
  #   port = 9000;
  #   settings = {
  #     bypassAuth = true;
  #     funnel = true;
  #   };
  # };

  # Create the data directory for MinIO
  systemd.tmpfiles.rules = [
    "d /mnt/storage/backups/minio 0700 minio minio -"
  ];
}
