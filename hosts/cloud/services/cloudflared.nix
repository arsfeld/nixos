# Cloudflared tunnel for cloud services
#
# Routes *.arsfeld.one traffic for cloud-hosted services through a dedicated
# Cloudflare Tunnel. Ingress rules are auto-generated from media.gateway.services.
# A DNS sync script ensures CNAME records exist for each service.
#
# Prerequisites:
#   1. Create tunnel: cloudflared tunnel create cloud-services
#   2. Store credentials in secrets/sops/cloud.yaml as cloudflare-tunnel-credentials-cloud
#   3. Update tunnelId below with the tunnel UUID
{
  config,
  lib,
  pkgs,
  ...
}: let
  tunnelId = "b0ab3f95-afba-4698-94b6-1083ee0bc6ad";
  domain = config.media.config.domain;
  services = config.media.gateway.services;
  serviceNames = builtins.attrNames services;
in {
  sops.secrets.cloudflare-tunnel-credentials-cloud = {};

  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = config.sops.secrets.cloudflare-tunnel-credentials-cloud.path;
      default = "http_status:404";
      originRequest = {
        noTLSVerify = true;
        originServerName = "tunnel.${domain}";
      };
      ingress = lib.listToAttrs (map (name: {
          name = "${name}.${domain}";
          value = "https://localhost";
        })
        serviceNames);
    };
  };

  # Sync Cloudflare DNS CNAME records for each cloud service → tunnel
  # Uses the existing Cloudflare API token (same one ACME uses for DNS challenges)
  systemd.services.cloudflare-dns-sync = {
    description = "Sync Cloudflare DNS records for cloud services";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = config.age.secrets.cloudflare.path;
    };
    path = [pkgs.python3];
    script = let
      hostnamesJson = builtins.toJSON (map (name: "${name}.${domain}") serviceNames);
    in ''
      python3 ${./cloudflare-dns-sync.py} \
        --tunnel-id "${tunnelId}" \
        --domain "${domain}" \
        --hostnames '${hostnamesJson}'
    '';
  };

  # Re-sync DNS records weekly in case of drift
  systemd.timers.cloudflare-dns-sync = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };
}
