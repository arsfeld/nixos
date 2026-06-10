# Vane = Perplexica-style AI search (model picked in the web UI, stored in
# /var/data/ask/config.json, not here). Uses OpenRouter.
#
# Model notes (updated 2026-06-10):
# - Recommended: openai/gpt-4o-mini — stable, 5x cheaper than Gemini 3 Preview,
#   reliably drives Vane's agentic search, and doesn't suffer from rate-limits
#   or 503 provider errors on OpenRouter. Note: requires the /home/vane/.next/server/chunks/136.js
#   patch mounted in volumes to avoid "Error:  is empty" crashes on streaming tool calls.
# - Unstable: google/gemini-3-flash-preview — frequently rate-limited/overloaded
#   upstream on OpenRouter, causing 503 errors and truncated JSON streams.
# - Cheaper but worse: gemini-2.5-flash / flash-lite — often misfire
#   Vane's search tool (emit the unsupported google_search action) and answer
#   ungrounded, so the cost saving isn't worth it.
# - deepseek/* — v4-flash is also fixed by the 136.js streaming tool-call patch, but
#   openai/gpt-4o-mini is preferred for stability and performance.
# Also: use the "speed" or "quality" optimization mode; "balanced" is broken
# upstream (crashes on google_search:search not found).
{config, ...}: let
  port = 3000;
in {
  media.containers.ask = {
    image = "itzcrazykns1337/vane:latest";
    listenPort = port;
    exposePort = port;
    configDir = "/home/vane/data";
    watchImage = true;
    environment = {
      SEARXNG_API_URL = "http://host.containers.internal:8888";
    };
  };

  media.gateway.services.ask.exposeViaTailscale = true;
}
