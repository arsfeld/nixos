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
      alerts = [{type = "custom";}];
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
    "ntfy"
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

  basestarServiceNames = [
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

  basestarEndpoints = map (name:
    mkEndpoint {
      inherit name;
      url = "https://${name}.arsfeld.dev";
      group = "basestar";
    })
  basestarServiceNames;

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
  # Publisher credential for gatus's ntfy.arsfeld.one alert webhook.
  # owner = arosenfeld + mode 0400 keeps the same ownership shape as every
  # other publisher-credential site (lets the user-mode claude-notify
  # script read it too, while systemd still loads it as EnvironmentFile).
  sops.secrets."ntfy-publisher-env" = {
    sopsFile = ../../../secrets/sops/ntfy-client.yaml;
    owner = "arosenfeld";
    mode = "0400";
  };

  services.gatus = {
    enable = true;
    # Gatus expands ${VAR} in its YAML config at load time via os.ExpandEnv.
    # The publisher credential is pre-computed as base64(user:pass) in the
    # sops secret so the alerter can assemble a Basic header without needing
    # a preStart template.
    environmentFile = config.sops.secrets."ntfy-publisher-env".path;
    settings = {
      web = {
        address = "127.0.0.1";
        port = gatusPort;
      };

      alerting = {
        # Gatus's native ntfy alerter requires tokens to start with `tk_`
        # (TokenPrefix = "tk_") and has no username/password or headers
        # field, so basic auth cannot be smuggled through. The generic
        # custom alerter accepts arbitrary headers, so we build the
        # Authorization header from NTFY_BASIC_AUTH_B64 exported by the
        # sops environmentFile.
        custom = {
          url = "https://ntfy.arsfeld.one/gatus";
          method = "POST";
          headers = {
            "Content-Type" = "text/plain";
            "Authorization" = "Basic \${NTFY_BASIC_AUTH_B64}";
            "Title" = "Gatus: [ENDPOINT_NAME]";
            "Priority" = "3";
            "Tags" = "warning";
          };
          body = "[ALERT_DESCRIPTION]";
          default-alert = {
            enabled = true;
            failure-threshold = 2;
            success-threshold = 2;
            send-on-resolved = true;
          };
        };
      };

      endpoints = storageEndpoints ++ basestarEndpoints ++ infraEndpoints;
    };
  };

  # Expose Gatus via tsnsrv for Tailscale-only access
  services.tsnsrv.services.gatus = {
    toURL = "http://127.0.0.1:${toString gatusPort}";
    funnel = false;
  };
}
