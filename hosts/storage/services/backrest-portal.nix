# Unified Backrest entry point.
#
# Single Caddy vhost `backrest.arsfeld.one` serves a small HTML portal
# with a host switcher (top row of pill-shaped sibling links) and an
# iframe that loads the selected host's Backrest UI from its public
# subdomain (see `backrest-public-vhosts.nix`).
#
# Each pill is a pair of sibling <a> elements wrapped in a
# `<div class="pill" role="group">`:
#   - The primary anchor uses href="#host=<name>" — clicks swap the
#     iframe via JS, fall back to a hash-only navigation without JS.
#   - The secondary anchor uses target="_blank" with the full
#     subdomain URL — always opens in a new tab (the R8 fallback).
#
# Sibling structure avoids the HTML5 nested-interactive violation
# (an <a> inside a <button> would yield event-bubbling ambiguity and
# accidentally swap the iframe when the user clicks the new-tab icon).
#
# The portal vhost itself sets `frame-ancestors 'none'` and
# `X-Frame-Options: DENY` so this admin-level page cannot be
# clickjacked from a third-party site.
#
# Trust model: the per-host backrest-<host>.arsfeld.one subdomains are
# Authelia-gated (see `backrest-public-vhosts.nix`); this portal vhost
# is also Authelia-gated. Authelia's session cookie is scoped to
# `arsfeld.one` so SSO carries across the iframe load.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Hosts that run constellation.backrest. Update this list as hosts
  # are migrated or retired. Pills render in this order.
  # NOTE: keep in sync with the same literal in backrest-public-vhosts.nix.
  backrestHosts = ["storage" "basestar" "pegasus" "raider"];

  renderPill = host: ''
    <div class="pill" role="group">
      <a href="#host=${host}" data-host="${host}">${host}</a>
      <a class="new-tab" href="https://backrest-${host}.arsfeld.one/" target="_blank" rel="noopener" aria-label="Open ${host} in new tab">↗</a>
    </div>'';

  hostsJson = builtins.toJSON backrestHosts;

  indexHtml = pkgs.writeTextDir "index.html" ''
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Backrest</title>
      <style>
        :root {
          color-scheme: dark;
          --bg: #1a1b26;
          --surface: #24283b;
          --border: #3b4261;
          --muted: #565f89;
          --text: #c0caf5;
          --accent: #7aa2f7;
          --accent-bg: #2f3556;
        }
        *, *::before, *::after { box-sizing: border-box; }
        html, body { height: 100%; }
        body {
          margin: 0;
          font-family: system-ui, -apple-system, sans-serif;
          background: var(--bg);
          color: var(--text);
          display: flex;
          flex-direction: column;
        }
        header {
          padding: 0.75rem 1rem;
          border-bottom: 1px solid var(--border);
          flex-shrink: 0;
        }
        h1 {
          margin: 0 0 0.5rem 0;
          font-weight: 500;
          color: var(--accent);
          font-size: 1.1rem;
        }
        nav.pills {
          display: flex;
          flex-wrap: wrap;
          gap: 0.5rem;
        }
        .pill {
          display: inline-flex;
          align-items: stretch;
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: 999px;
          overflow: hidden;
          transition: border-color .15s;
        }
        .pill:hover { border-color: var(--accent); }
        .pill a {
          display: inline-flex;
          align-items: center;
          min-height: 44px;
          padding: 0 1rem;
          color: var(--text);
          text-decoration: none;
          font-size: 0.95rem;
        }
        .pill a:focus-visible {
          outline: 2px solid var(--accent);
          outline-offset: -2px;
        }
        .pill a[aria-current="page"] {
          background: var(--accent-bg);
          color: var(--accent);
        }
        .pill .new-tab {
          padding: 0 0.85rem;
          border-left: 1px solid var(--border);
          color: var(--muted);
          font-size: 1rem;
        }
        .pill .new-tab:hover { color: var(--accent); }
        iframe {
          flex: 1;
          width: 100%;
          border: 0;
          background: var(--bg);
        }
      </style>
    </head>
    <body>
      <header>
        <h1>Backrest</h1>
        <nav class="pills" aria-label="Backrest hosts">
          ${lib.concatMapStringsSep "\n      " renderPill backrestHosts}
        </nav>
      </header>
      <iframe id="host-frame" src="about:blank" title="Backrest UI"></iframe>
      <script>
        (function () {
          var hosts = ${hostsJson};
          var frame = document.getElementById('host-frame');
          var pillLinks = document.querySelectorAll('a[data-host]');

          function urlFor(host) {
            return 'https://backrest-' + host + '.arsfeld.one/';
          }

          function activate(host) {
            if (hosts.indexOf(host) === -1) host = hosts[0];
            frame.src = urlFor(host);
            pillLinks.forEach(function (a) {
              if (a.dataset.host === host) {
                a.setAttribute('aria-current', 'page');
              } else {
                a.removeAttribute('aria-current');
              }
            });
          }

          function readHost() {
            var m = location.hash.match(/host=([a-z0-9-]+)/);
            return m ? m[1] : hosts[0];
          }

          pillLinks.forEach(function (a) {
            a.addEventListener('click', function (e) {
              e.preventDefault();
              var host = a.dataset.host;
              location.hash = 'host=' + host;
              activate(host);
            });
          });

          window.addEventListener('hashchange', function () {
            activate(readHost());
          });

          activate(readHost());
        })();
      </script>
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

      header {
        # `>` prefix forces replace semantics (default `header` appends,
        # which would duplicate XFO since Authelia's 302 already sets it).
        >Content-Security-Policy "frame-ancestors 'none'"
        >X-Frame-Options "DENY"
      }

      root * ${indexHtml}
      file_server
    '';
  };
}
