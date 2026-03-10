# Gatus uptime monitoring service
#
# Monitors all homelab services from cloud (external vantage point).
# Alerts via ntfy on service failures.
#
# Storage services use an external DNS resolver (8.8.8.8) to bypass
# Tailscale MagicDNS, which would resolve *.arsfeld.one to Tailscale IPs
# instead of Cloudflare proxy IPs. This ensures we test the actual public
# path: Cloudflare -> cloudflared tunnel -> storage.
{
  config,
  lib,
  ...
}: let
  gatusPort = 8090;

  mkEndpoint = {
    name,
    url,
    group,
    interval ? "60s",
    conditions ? [
      "[CONNECTED] == true"
      "[RESPONSE_TIME] < 5000"
    ],
    client ? {},
  }:
    {
      inherit name url group interval conditions;
      alerts = [{type = "ntfy";}];
    }
    // lib.optionalAttrs (client != {}) {inherit client;};

  # External DNS resolver to bypass Tailscale MagicDNS
  externalDns = {dns-resolver = "tcp://8.8.8.8:53";};

  storageServiceNames = [
    "auth"
    "code"
    "filebrowser"
    "fileflows"
    "filestash"
    "forgejo"
    "grafana"
    "hass"
    "home"
    "immich"
    "komga"
    "lidarr"
    "n8n"
    "netdata"
    "nextcloud"
    "opencloud"
    "resilio"
    "romm"
    "speedtest"
    "syncthing"
    "tautulli"
    "vault"
    "yarr"
  ];

  cloudServiceNames = [
    "blog"
    "planka"
    "plausible"
    "siyuan"
  ];

  storageEndpoints = map (name:
    mkEndpoint {
      inherit name;
      url = "https://${name}.arsfeld.one";
      group = "storage";
      client = externalDns;
    })
  storageServiceNames;

  cloudEndpoints = map (name:
    mkEndpoint {
      inherit name;
      url = "https://${name}.arsfeld.dev";
      group = "cloud";
    })
  cloudServiceNames;

  infraEndpoints = [
    (mkEndpoint {
      name = "Internet";
      url = "https://1.1.1.1";
      group = "infrastructure";
      interval = "120s";
      conditions = ["[CONNECTED] == true"];
    })
    (mkEndpoint {
      name = "DNS Resolution";
      url = "https://arsfeld.one";
      group = "infrastructure";
      interval = "120s";
      client = externalDns;
    })
    (mkEndpoint {
      name = "Tailscale - Storage";
      url = "tcp://storage.bat-boa.ts.net:22";
      group = "infrastructure";
      interval = "120s";
      conditions = ["[CONNECTED] == true"];
    })
  ];
in {
  services.gatus = {
    enable = true;
    settings = {
      web = {
        address = "127.0.0.1";
        port = gatusPort;
      };

      alerting = {
        ntfy = {
          topic = "arsfeld-gatus";
          url = "https://ntfy.sh";
          priority = 3;
          default-alert = {
            enabled = true;
            failure-threshold = 2;
            success-threshold = 2;
            send-on-resolved = true;
          };
        };
      };

      endpoints = storageEndpoints ++ cloudEndpoints ++ infraEndpoints;
    };
  };

  # Expose Gatus via tsnsrv for Tailscale-only access
  services.tsnsrv.services.gatus = {
    toURL = "http://127.0.0.1:${toString gatusPort}";
    funnel = false;
  };
}
