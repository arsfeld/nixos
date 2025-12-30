{
  config,
  pkgs,
  self,
  ...
}: {
  imports = [
    ./plex.nix
  ];

  # Create garage user/group early so agenix can chown secrets
  users.users.garage = {
    isSystemUser = true;
    group = "garage";
  };
  users.groups.garage = {};

  # Age secret for Garage RPC secret (32-byte hex string)
  age.secrets."garage-rpc-secret" = {
    file = "${self}/secrets/garage-rpc-secret.age";
    owner = "garage";
    group = "garage";
    mode = "0400";
  };

  # Age secret for Garage admin token
  age.secrets."garage-admin-token" = {
    file = "${self}/secrets/garage-admin-token.age";
    owner = "garage";
    group = "garage";
    mode = "0400";
  };

  # Enable and configure Garage as S3-compatible backup destination
  services.garage = {
    enable = true;
    package = pkgs.garage_2;
    settings = {
      metadata_dir = "/mnt/storage/backups/garage/meta";
      data_dir = "/mnt/storage/backups/garage/data";
      db_engine = "lmdb";

      replication_factor = 1;

      rpc_bind_addr = "[::]:3901";
      rpc_public_addr = "127.0.0.1:3901";
      rpc_secret_file = config.age.secrets.garage-rpc-secret.path;

      s3_api = {
        api_bind_addr = "[::]:3900";
        s3_region = "garage";
        root_domain = ".s3.garage.localhost";
      };

      s3_web = {
        bind_addr = "[::]:3902";
        root_domain = ".web.garage.localhost";
      };

      admin = {
        api_bind_addr = "[::]:3903";
        admin_token_file = config.age.secrets.garage-admin-token.path;
      };
    };
  };

  # Create the data directories for Garage
  systemd.tmpfiles.rules = [
    "d /mnt/storage/backups/garage 0750 garage garage -"
    "d /mnt/storage/backups/garage/meta 0750 garage garage -"
    "d /mnt/storage/backups/garage/data 0750 garage garage -"
  ];
}
