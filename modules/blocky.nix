# Blocky DNS server module
#
# This module configures Blocky, a fast and lightweight DNS proxy with ad-blocking
# capabilities. It provides DNS services with upstream resolvers, caching, and
# filtering for ads and tracking domains.
#
# Key features:
# - Ad blocking using Steven Black's hosts list
# - DNS caching with Redis backend for persistence
# - Custom DNS mappings for local domains
# - Prometheus metrics exposure
# - Tailscale integration with .ts.net domain rewrites
#
# The module integrates with the media gateway services when enabled.
{
  lib,
  config,
  self,
  ...
}: let
  services = config.media.gateway.services;
in {
  options.blocky = {
    enable = lib.mkEnableOption "Blocky DNS server with ad-blocking capabilities";
  };

  config = lib.mkIf config.blocky.enable {
    services.redis = {
      servers = {
        blocky = {
          enable = false;
          user = "blocky";
          settings = {
            "protected-mode" = "no";
          };
        };
      };
    };

    services.blocky = {
      enable = true;
      settings = {
        queryLog.type = "none";
        upstreams = {
          groups = {
            default = ["1.1.1.2" "1.0.0.2"];
          };
        };
        ports = {
          http = ":${toString services.dns.port}";
        };
        redis = {
          address = "100.66.38.77:6378";
          database = 2;
          required = false;
          connectionAttempts = 20;
          connectionCooldown = "6s";
        };
        caching = {
          minTime = "5m";
          prefetching = true;
        };
        customDNS = {
          mapping = {
            "arsfeld.one" = lib.mkDefault "192.168.1.5"; # "100.118.254.136";
          };
        };
        conditional = {
          rewrite = {
            lan = "bat-boa.ts.net";
          };
          mapping = {
            "ts.net" = "100.100.100.100";
          };
        };
        bootstrapDns = "tcp+udp:1.1.1.1";
        blocking = {
          blackLists = {
            ads = [
              "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
            ];
          };
          clientGroupsBlock = {
            default = ["ads"];
          };
        };
        prometheus = {
          enable = true;
          path = "/metrics";
        };
      };
    };
  };
}
