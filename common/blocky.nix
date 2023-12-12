{lib, ...}: {
  services.blocky = {
    enable = true;
    settings = {
      upstreams = {
        groups = {
          default = ["1.1.1.1" "9.9.9.9"];
        };
      };
      ports = {
        http = ":4000";
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
            "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"
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
}
