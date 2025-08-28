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
    lanAuthoritative = {
      enable = lib.mkEnableOption "Forward LAN zones to a local authoritative DNS (for DDNS integration)";
      upstream = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:5353";
        description = "Authoritative DNS upstream (host:port) for LAN zones (e.g., BIND listening on 127.0.0.1:5353).";
      };
      zones = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["lan"];
        description = "Zones to forward to the authoritative upstream (e.g., [\"lan\", \"1.1.10.in-addr.arpa\"]).";
      };
    };
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
        conditional = lib.mkMerge [
          {
            rewrite = {
              lan = "bat-boa.ts.net";
            };
            mapping = {
              "ts.net" = "100.100.100.100";
            };
          }
          (lib.mkIf config.blocky.lanAuthoritative.enable {
            # Forward configured LAN zones to the local authoritative server
            mapping = lib.listToAttrs (map (z: {
                name = z;
                value = config.blocky.lanAuthoritative.upstream;
              })
              config.blocky.lanAuthoritative.zones);
          })
        ];
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
