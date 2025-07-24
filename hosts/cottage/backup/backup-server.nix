{ config, pkgs, ... }:

{
  # Create buckets for backups in MinIO
  systemd.services.minio-buckets = {
    description = "Create MinIO buckets for backups";
    wantedBy = [ "minio.service" ];
    after = [ "minio.service" ];
    requires = [ "minio.service" ];
    path = with pkgs; [ minio-client ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for MinIO to be ready
      until mc alias set local http://localhost:9000 $(cat ${config.age.secrets.minio-credentials.path} | cut -d' ' -f1) $(cat ${config.age.secrets.minio-credentials.path} | cut -d' ' -f2); do
        echo "Waiting for MinIO to be ready..."
        sleep 5
      done
      
      # Create buckets if they don't exist
      mc mb local/system-backups || true
      mc mb local/media-backups || true
      
      # Set bucket policies to private
      mc anonymous set none local/system-backups || true
      mc anonymous set none local/media-backups || true
    '';
  };
}