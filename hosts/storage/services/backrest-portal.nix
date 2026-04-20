# Caddy vhosts for per-host Backrest UIs.
#
# Each migrated host runs its own Backrest daemon on :9898 bound to
# tailscale0; this portal proxies backrest-<host>.arsfeld.one to the
# corresponding daemon over Tailscale. Authelia is enforced by the
# gateway's default (bypassAuth = false).
#
# The `host =` field feeds into modules/media/__utils.nix's
# reverse_proxy generator. Whether bare short-name resolution
# (basestar:9898) works from storage's Caddy context vs. needing the
# FQDN (basestar.bat-boa.ts.net:9898) is an open item flagged in the
# plan — discover on first deploy and extend the gateway utils only if
# short-name resolution fails.
{
  media.gateway.services.backrest-basestar = {
    host = "basestar";
    port = 9898;
  };
}
