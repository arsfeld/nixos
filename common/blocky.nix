{
  lib,
  pkgs,
  ...
}: let
  blocky_overlay = self: super: {
    blocky = super.callPackage "${super.path}/pkgs/applications/networking/blocky" {
      buildGoModule = args:
        super.buildGoModule (args
          // {
            vendorHash = "sha256-9n9IXmzhBB2YRDLiQPUQAdlcHZsn0xK3NZkHPTK5JeA=";
            version = "git";
            src = pkgs.fetchFromGitHub {
              owner = "0xERR0R";
              repo = "blocky";
              rev = "abe9e5c46133455eefea620d04c545b91f3f2ca9";
              sha256 = "qi40sXzZPhDZ90s6HjwLtMz0VfQ9wQkyoNWv3gXDFzw=";
            };
          });
    };
  };
in {
  nixpkgs.overlays = [blocky_overlay];

  services.blocky = {
    enable = true;
    settings = {
      upstreams = {
        groups = {
          default = ["tcp-tls:security.cloudflare-dns.com"];
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
