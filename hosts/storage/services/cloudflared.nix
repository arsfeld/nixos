{config, ...}: {
  sops.secrets.cloudflare-tunnel-credentials = {};

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
