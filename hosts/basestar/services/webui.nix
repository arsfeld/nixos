{
  config,
  lib,
  ...
}: {
  sops.secrets."open-webui-env" = {};

  media.services.webui = {
    port = 8080;
    image = "ghcr.io/open-webui/open-webui:main";
    bypassAuth = true; # Open WebUI has its own login; CF edge in front
    tailscaleExposed = true; # webui.bat-boa.ts.net
    watchImage = true;
    container = {
      configDir = "/app/backend/data"; # -> /var/data/webui:/app/backend/data
      # Reaches the host's native SearXNG via host.containers.internal
      # (provided automatically by podman).
      environmentFiles = [config.sops.secrets."open-webui-env".path];
      environment = {
        # OpenRouter as the OpenAI-compatible backend (key is in env file).
        OPENAI_API_BASE_URL = "https://openrouter.ai/api/v1";
        # Web search via the host's native SearXNG.
        ENABLE_WEB_SEARCH = "true";
        WEB_SEARCH_ENGINE = "searxng";
        SEARXNG_QUERY_URL = "http://host.containers.internal:8888/search?q=<query>";
        # Reranking: hybrid search + a CPU cross-encoder (downloaded at runtime).
        ENABLE_RAG_HYBRID_SEARCH = "true";
        RAG_RERANKING_MODEL = "BAAI/bge-reranker-v2-m3";
      };
    };
  };
}
