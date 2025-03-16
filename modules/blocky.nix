{
  lib,
  config,
  self,
  ...
}: let
  ports = config.media.gateway.ports;
in {
  options.blocky = {
    enable = lib.mkEnableOption "blocky";
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
          http = ":${toString ports.dns}";
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
