{
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;
in {
  imports = [
  ];

  # MinIO service disabled until data pool is recreated
  # # Enable and configure MinIO as S3-compatible backup destination
  # services.minio = {
  #   enable = true;
  #   rootCredentialsFile = config.age.secrets.minio-credentials.path;
  #   dataDir = [ "/mnt/storage/backups/minio" ];
  #   listenAddress = ":9000";
  #   consoleAddress = ":9001";
  #   region = "auto";
  # };

  # # Add MinIO to the media gateway
  # media.gateway.services.minio = {
  #   host = "cottage";
  #   port = 9000;
  #   settings = {
  #     bypassAuth = true;
  #     funnel = true;
  #   };
  # };

  # # Create the data directory for MinIO
  # systemd.tmpfiles.rules = [
  #   "d /mnt/storage/backups/minio 0700 ${vars.user} ${vars.group} -"
  # ];
}
