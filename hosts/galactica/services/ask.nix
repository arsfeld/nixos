{...}: {
  # Vane (renamed from Perplexica upstream on 2026-03-09) — ask.arsfeld.one.
  # Perplexity-shaped answer engine: SearXNG for retrieval, an LLM for the
  # synthesis, citations inline.
  #
  # It lives on galactica rather than basestar for two reasons: galactica's
  # Caddy is what *.arsfeld.one actually terminates on (the cloudflared tunnel
  # sends the whole wildcard to https://localhost here, and tailnet DNS points
  # the same names at this host), and SearXNG is native here — so retrieval is
  # a loopback hop instead of a trip across the tailnet.
  #
  # Replaces morphic, which held this name on basestar until 2026-09-05 but
  # only ever answered on ask.bat-boa.ts.net — ask.arsfeld.one 404'd, because
  # a gateway entry on basestar cannot produce a vhost on galactica's Caddy.
  # Its database and sops secret were deliberately left behind on basestar to
  # keep the revert cheap.
  #
  # `slim-latest`, not `latest`: the fat tag bundles its own SearXNG, which is
  # pointless next to the tuned instance in ./search.nix. Upstream tags
  # releases rarely and ships from master, so `latest` is the only practical
  # channel — hence watchImage rather than a pinned version.
  media.services.ask = {
    port = 3000;
    image = "itzcrazykns1337/vane:slim-latest";
    # NOT bypassAuth: ask.arsfeld.one is reachable from the public internet
    # through the tunnel, and Vane ships no login of its own — unlike webui or
    # stash, there is nothing behind it to fall back on. Authelia is the only
    # thing standing between the open internet and an endpoint that spends
    # API credits. ask.bat-boa.ts.net is unaffected either way; tsnsrv nodes
    # never get Authelia (Tailscale is the network-level auth there).
    tailscaleExposed = true; # ask.bat-boa.ts.net
    watchImage = true;
    container = {
      # config.json, db.sqlite and uploads/ all live under this single dir
      # (src/lib/config/index.ts, src/lib/db/index.ts, src/lib/uploads/manager.ts),
      # so one mount covers all of Vane's state. -> /var/data/ask:/home/vane/data
      configDir = "/home/vane/data";
      environment = {
        SEARXNG_API_URL = "http://host.containers.internal:8888";
      };
    };
  };
  # No sops secret on purpose: SEARXNG_API_URL is the *only* setting Vane reads
  # from the environment (the lone field carrying an `env:` mapping in
  # src/lib/config/index.ts). Provider, API key and model are entered once in
  # the first-run setup wizard and persisted to config.json in the volume above,
  # so they cannot be seeded declaratively the way webui.nix seeds its own.
}
