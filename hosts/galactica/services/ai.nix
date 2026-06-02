{
  self,
  config,
  pkgs,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  vars = config.media.config;
in
  lib.mkMerge [
    # ollama-api is a gateway alias for the ollama container's published port.
    (mkService "ollama-api" {
      port = 11434;
      bypassAuth = true;
    })

    (mkService "n8n" {
      port = 5678;
      image = "n8nio/n8n:latest";
      tailscaleExposed = true;
      container = {
        exposePort = 5678;
        configDir = null;
        network = "ai";
        environment = {
          N8N_DIAGNOSTICS_ENABLED = "false";
          N8N_PERSONALIZATION_ENABLED = "false";
          N8N_HOST = "n8n.${vars.domain}";
          WEBHOOK_URL = "https://n8n.${vars.domain}/";
          OLLAMA_HOST = "ollama:11434";
        };
        volumes = [
          "${vars.configDir}/n8n/n8n_storage:/home/node/.n8n"
          "${vars.configDir}/n8n/backup:/backup"
          "${vars.configDir}/n8n/shared:/data/shared"
        ];
      };
    })

    # qdrant has no gateway entry; it talks to n8n over the "ai" podman network.
    (mkService "qdrant" {
      image = "qdrant/qdrant";
      container = {
        configDir = null;
        network = "ai";
        volumes = ["qdrant_storage:/qdrant/storage"];
        extraOptions = ["--publish=6333:6333"];
      };
    })

    # IPEX-LLM build of ollama for Intel iGPU acceleration (Iris Xe via SYCL).
    # Storage CPU is Raptor Lake-P; the iGPU shares system RAM, so the speedup
    # is modest (mostly prompt processing). To revert: switch image back to
    # ollama/ollama:latest and drop the env vars and device mappings below.
    (mkService "ollama" {
      image = "ghcr.io/ava-agentone/ollama-intel:latest";
      container = {
        configDir = null;
        network = "ai";
        devices = [
          "/dev/dri/card0"
          "/dev/dri/renderD128"
        ];
        environment = {
          OLLAMA_HOST = "0.0.0.0:11434";
          OLLAMA_NUM_GPU = "999";
          OLLAMA_KEEP_ALIVE = "5m";
          # Default context. Clients (e.g. Vane) request 32k+ which blows the
          # KV cache to 9GB on this 8B model; cap to 8k unless overridden.
          OLLAMA_CONTEXT_LENGTH = "8192";
          # Single sequence — KV cache is shared across parallel slots, so
          # 2 parallel sequences double the cache size.
          OLLAMA_NUM_PARALLEL = "1";
          ONEAPI_DEVICE_SELECTOR = "level_zero:0";
          ZES_ENABLE_SYSMAN = "1";
          SYCL_CACHE_PERSISTENT = "1";
        };
        volumes = [
          "${vars.configDir}/ollama:/root/.ollama"
        ];
        extraOptions = [
          "--publish=11434:11434"
          "--group-add=303" # render
          "--group-add=26" # video
          "--shm-size=4g"
        ];
      };
    })

    {
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
  ]
