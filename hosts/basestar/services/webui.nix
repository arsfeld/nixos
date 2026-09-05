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
      environmentFiles = [config.sops.secrets."open-webui-env".path];
      environment = {
        # OpenRouter as the OpenAI-compatible backend (key is in env file).
        OPENAI_API_BASE_URL = "https://openrouter.ai/api/v1";
        # Web search via galactica's SearXNG over the tailnet. basestar has no
        # SearXNG of its own — this pointed at host.containers.internal:8888
        # until 2026-09-05, a basestar-local instance that has not existed
        # since the failover stack was retired (see the note in ./default.nix),
        # so web search silently returned nothing rather than erroring. It is
        # reachable across the tailnet without a firewall rule because
        # constellation.common trusts tailscale0 on every host.
        ENABLE_WEB_SEARCH = "true";
        WEB_SEARCH_ENGINE = "searxng";
        SEARXNG_QUERY_URL = "http://galactica.bat-boa.ts.net:8888/search?q=<query>";
        # Reranking: hybrid search + a CPU cross-encoder (downloaded at runtime).
        ENABLE_RAG_HYBRID_SEARCH = "true";
        RAG_RERANKING_MODEL = "BAAI/bge-reranker-v2-m3";
      };
    };
  };
}
