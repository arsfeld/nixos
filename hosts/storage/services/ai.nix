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
      n8n = {
        image = "n8nio/n8n:latest";
        environment = {
          N8N_DIAGNOSTICS_ENABLED = "false";
          N8N_PERSONALIZATION_ENABLED = "false";
          N8N_HOST = "n8n.${config.media.config.domain}";
          WEBHOOK_URL = "https://n8n.${config.media.config.domain}/";
          OLLAMA_HOST = "ollama:11434";
          # Add N8N_ENCRYPTION_KEY and N8N_USER_MANAGEMENT_JWT_SECRET as needed
        };
        volumes = [
          "${config.media.config.configDir}/n8n/n8n_storage:/home/node/.n8n"
          "${config.media.config.configDir}/n8n/backup:/backup"
          "${config.media.config.configDir}/n8n/shared:/data/shared"
        ];
        # user = "${config.media.config.user}:${config.media.config.group}";
        ports = ["5678:5678"];
        extraOptions = ["--network=ai"];
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
          "${config.media.config.configDir}/ollama:/root/.ollama"
        ];
        ports = ["11434:11434"];
        extraOptions = ["--network=ai"];
      };
    };
  };

  # Create the docker network
  systemd.services.create-podman-ai-network = {
    description = "Create Podman AI Network";
    after = ["podman.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "create-podman-ai-network" ''
        ${pkgs.podman}/bin/podman network create ai || true
      '';
    };
  };
}
