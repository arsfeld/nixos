# Cloudflare tunnel for arsfeld.one — reuses galactica's tunnel so
# *.arsfeld.one DNS stays pointed at the same tunnel UUID. Multiple
# cloudflared instances can serve the same tunnel (Cloudflare supports
# connector redundancy).
#
# Tunnel UUID + credentials copied from galactica into basestar's sops file.
{config, ...}: {
  sops.secrets.cloudflare-tunnel-credentials = {
    sopsFile = ../../../secrets/sops/basestar.yaml;
  };
  services.cloudflared = {
    enable = true;
    tunnels = {
      "f53e532a-783b-4e78-a373-23dd749d1faa" = {
        credentialsFile = config.sops.secrets.cloudflare-tunnel-credentials.path;
        default = "http_status:404";
        originRequest = {
          noTLSVerify = true;
          originServerName = "tunnel.arsfeld.one";
        };
        ingress = {
          "*.arsfeld.one" = "https://localhost";
          "arsfeld.one" = "https://localhost";
        };
      };
    };
  };
}
