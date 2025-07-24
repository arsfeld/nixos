{
  pkgs,
  config,
  self,
  ...
}: {
  imports = [
    ./backup-server.nix
  ];

  # Configure secrets for MinIO
  age.secrets.minio-credentials.file = "${self}/secrets/minio-credentials.age";
}