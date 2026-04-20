# Unified Backrest entry-point.
#
# Single Caddy vhost `backrest.arsfeld.one` serves a static HTML picker
# page. Each card links to a host's Backrest UI at
# `http://<host>.bat-boa.ts.net:9898/`.
#
# Trust model: Backrest daemons bind tailscale0 only, so the actual UIs
# require tailnet. Authelia gates the landing page itself to keep the
# host list out of random public view. Path-based proxying is not
# viable — Backrest has no base-URL support; its SPA and API calls
# assume `/` root.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Hosts that run constellation.backrest. Update this list as hosts
  # are migrated or retired. Cards render in this order.
  backrestHosts = [
    "basestar"
    "pegasus"
    "raider"
    "storage"
  ];

  renderCard = host: ''
    <a class="card" href="http://${host}.bat-boa.ts.net:9898/">
      <h2>${host}</h2>
      <code>${host}.bat-boa.ts.net:9898</code>
    </a>'';

  indexHtml = pkgs.writeTextDir "index.html" ''
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Backrest</title>
      <style>
        :root { color-scheme: dark; }
        body { font-family: system-ui, sans-serif; background: #1a1b26; color: #c0caf5; margin: 0; padding: 2rem; }
        h1 { margin: 0 0 .25rem 0; font-weight: 500; color: #7aa2f7; }
        p.sub { margin: 0 0 2rem 0; color: #565f89; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 1rem; max-width: 1100px; }
        .card { display: block; background: #24283b; border: 1px solid #3b4261; border-radius: 8px; padding: 1rem 1.25rem; text-decoration: none; color: inherit; transition: border-color .15s, transform .15s; }
        .card:hover { border-color: #7aa2f7; transform: translateY(-1px); }
        .card h2 { margin: 0 0 .25rem 0; font-size: 1.1rem; color: #c0caf5; }
        .card code { color: #9ece6a; font-size: .85rem; word-break: break-all; }
        footer { margin-top: 2rem; color: #565f89; font-size: .85rem; max-width: 1100px; }
      </style>
    </head>
    <body>
      <h1>Backrest</h1>
      <p class="sub">Per-host backup orchestrators. Pick a host to view its plans, runs, and logs.</p>
      <div class="grid">
        ${lib.concatMapStringsSep "\n    " renderCard backrestHosts}
      </div>
      <footer>Links go to each host's Backrest UI on the tailnet (port 9898). You must be on the tailnet for the links to resolve.</footer>
    </body>
    </html>
  '';

  authHost = config.media.gateway.authHost;
  authPort = config.media.gateway.authPort;
  authScheme =
    if authHost == "127.0.0.1"
    then ""
    else "https://";
in {
  services.caddy.virtualHosts."backrest.arsfeld.one" = {
    useACMEHost = "arsfeld.one";
    extraConfig = ''
      import errors

      forward_auth ${authScheme}${authHost}:${toString authPort} {
        uri /api/authz/forward-auth?authelia_url=https://auth.arsfeld.one
        header_up X-Forwarded-Method {method}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Uri {uri}
        header_up X-Original-URL {scheme}://{host}{uri}
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
      }

      root * ${indexHtml}
      file_server
    '';
  };
}
