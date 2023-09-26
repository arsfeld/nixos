{...}: {
  services.blocky = {
    enable = true;
    settings = {
      upstream = {
        default = ["1.1.1.1" "9.9.9.9"];
      };
      caching = {
        minTime = "5m";
        prefetching = true;
      };
      customDNS = {
        mapping = {
          "arsfeld.one" = "100.101.207.61";
        };
      };
      conditional = {
        rewrite = {
          lan = "penguin-gecko.ts.net";
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
