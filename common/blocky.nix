{...}: {
  services.blocky = {
    enable = true;
    settings = {
      upstream = {
        default = ["1.1.1.1" "9.9.9.9"];
      };
      customDNS = {
        mapping = {
          "arsfeld.one" = "192.168.31.15";
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
