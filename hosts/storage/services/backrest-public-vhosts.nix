# Public per-host Backrest subdomains.
#
# Each host running constellation.backrest gets a Caddy vhost on storage at
# `backrest-<host>.arsfeld.one`. Storage's Caddy reverse-proxies over the
# tailnet to <host>.bat-boa.ts.net:9898 (localhost for storage's own
# daemon to skip the loopback). Authelia gates every subdomain via the
# same forward_auth pattern as the other internal services.
#
# Two header concerns under storage's authority (R11):
#   - CSP `frame-ancestors https://backrest.arsfeld.one` so only the
#     portal page may iframe these subdomains.
#   - Top-level `header { -X-Frame-Options }` strips any upstream value
#     unconditionally so the CSP directive is the sole framing
#     authority. (Single mechanism — `header_down` inside reverse_proxy
#     would not run on Authelia's 302 path.)
#
# The host list is a literal here AND in `backrest-portal.nix`. Two
# four-element lists kept in sync by convention; if they drift the
# symptom is a portal pill that 404s, or a public vhost with no portal
# entry. Per the R4 cut decision in the brainstorm, deriving the list
# from constellation config is explicit non-goal.
{
  config,
  lib,
  ...
}: let
  backrestHosts = ["storage" "basestar" "pegasus" "raider"];

  authHost = config.media.gateway.authHost;
  authPort = config.media.gateway.authPort;
  authScheme =
    if authHost == "127.0.0.1"
    then ""
    else "https://";

  upstream = host:
    if host == "storage"
    then "localhost:9898"
    else "${host}.bat-boa.ts.net:9898";

  mkVhost = host: {
    name = "backrest-${host}.arsfeld.one";
    value = {
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
          Content-Security-Policy "frame-ancestors https://backrest.arsfeld.one"
          -X-Frame-Options
        }

        reverse_proxy http://${upstream host}
      '';
    };
  };
in {
  services.caddy.virtualHosts = builtins.listToAttrs (map mkVhost backrestHosts);
}
