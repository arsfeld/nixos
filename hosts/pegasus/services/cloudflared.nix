# Cloudflare tunnel for pegasus's public domain (arsfeld.xyz).
#
# Mirrors galactica's tunnel (hosts/galactica/services/cloudflared.nix) but for
# arsfeld.xyz. The tunnel only needs outbound connectivity, so it survives NAT,
# DHCP and the physical move.
#
# Tunnel UUID + credentials are configured. Remaining manual Cloudflare steps:
#   1. DNS: add `*.arsfeld.xyz` and `arsfeld.xyz` as CNAME ->
#      84e31a07-b00b-4295-822d-995cc812519a.cfargotunnel.com (proxied).
#   2. Ensure the `cloudflare` API token (common.yaml, used for ACME DNS-01)
#      is authorized for the arsfeld.xyz zone, or Caddy can't issue certs.
{config, ...}: {
  sops.secrets.cloudflare-tunnel-credentials = {
    sopsFile = ../../../secrets/sops/pegasus.yaml;
  };

  services.cloudflared = {
    enable = true;
    tunnels = {
      "84e31a07-b00b-4295-822d-995cc812519a" = {
        credentialsFile = config.sops.secrets.cloudflare-tunnel-credentials.path;
        default = "http_status:404";
        originRequest = {
          noTLSVerify = true;
          originServerName = "tunnel.arsfeld.xyz";
        };
        ingress = {
          "*.arsfeld.xyz" = "https://localhost";
          "arsfeld.xyz" = "https://localhost";
        };
      };
    };
  };
}
