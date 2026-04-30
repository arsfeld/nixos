{
  config,
  pkgs,
  lib,
  ...
}: {
  media.gateway.services.n8n = {
    port = 5678;
    exposeViaTailscale = true;
  };
  media.gateway.services.ollama-api = {
    port = 11434;
    settings.bypassAuth = true;
  };
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
        # IPEX-LLM build of ollama for Intel iGPU acceleration (Iris Xe via SYCL).
        # Storage CPU is Raptor Lake-P; the iGPU shares system RAM, so the speedup
        # is modest (mostly prompt processing). To revert: switch image back to
        # ollama/ollama:latest and drop the env vars and device mappings below.
        image = "ghcr.io/ava-agentone/ollama-intel:latest";
        environment = {
          OLLAMA_HOST = "0.0.0.0:11434";
          OLLAMA_NUM_GPU = "999";
          OLLAMA_KEEP_ALIVE = "30s";
          ONEAPI_DEVICE_SELECTOR = "level_zero:0";
          ZES_ENABLE_SYSMAN = "1";
          SYCL_CACHE_PERSISTENT = "1";
        };
        volumes = [
          "${config.media.config.configDir}/ollama:/root/.ollama"
        ];
        ports = ["11434:11434"];
        extraOptions = [
          "--network=ai"
          "--device=/dev/dri/card1"
          "--device=/dev/dri/renderD128"
          "--group-add=303" # render
          "--group-add=26" # video
          "--shm-size=4g"
        ];
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
