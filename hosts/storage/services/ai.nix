{
  config,
  pkgs,
  lib,
  ...
}: {
  # services.ollama = {
  #   enable = true;
  #   loadModels = ["llama3.1"];
  #   host = "0.0.0.0";
  #   environmentVariables = {
  #     OLLAMA_ORIGINS = "https://ollama-api.arsfeld.one";
  #   };
  # };

  virtualisation.oci-containers = {
    containers = {
      postgres = {
        image = "postgres:16-alpine";
        environment = {
          POSTGRES_USER = "n8n";
          POSTGRES_PASSWORD = "password"; # Consider using a secret
          POSTGRES_DB = "n8n";
        };
        volumes = [
          "postgres_storage:/var/lib/postgresql/data"
        ];
        extraOptions = ["--network=ai"];
      };

      n8n = {
        image = "n8nio/n8n:latest";
        environment = {
          DB_TYPE = "postgresdb";
          DB_POSTGRESDB_HOST = "postgres";
          DB_POSTGRESDB_USER = "n8n";
          DB_POSTGRESDB_PASSWORD = "password"; # Should match postgres password
          N8N_DIAGNOSTICS_ENABLED = "false";
          N8N_PERSONALIZATION_ENABLED = "false";
          OLLAMA_HOST = "ollama:11434";
          # Add N8N_ENCRYPTION_KEY and N8N_USER_MANAGEMENT_JWT_SECRET as needed
        };
        volumes = [
          "n8n_storage:/home/node/.n8n"
          "./n8n/backup:/backup"
          "./shared:/data/shared"
        ];
        ports = ["5678:5678"];
        extraOptions = ["--network=ai"];
        dependsOn = ["postgres"];
      };

      qdrant = {
        image = "qdrant/qdrant";
        volumes = [
          "qdrant_storage:/qdrant/storage"
        ];
        ports = ["6333:6333"];
        extraOptions = ["--network=ai"];
      };

      ollama = {
        image = "ollama/ollama:latest";
        volumes = [
          "${config.mediaConfig.configDir}/ollama:/root/.ollama"
        ];
        ports = ["11434:11434"];
        extraOptions = ["--network=ai"];
      };
    };
  };

  # Create the docker network
  systemd.services.create-docker-network = {
    description = "Create Docker Network";
    after = ["docker.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.docker}/bin/docker network create ai || true";
    };
  };
}
