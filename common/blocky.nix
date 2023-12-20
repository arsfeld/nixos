{
  lib,
  pkgs,
  ...
}: let
  # Fixing https://github.com/0xERR0R/blocky/issues/1113
  blocky_overlay = self: super: {
    blocky = super.callPackage "${super.path}/pkgs/applications/networking/blocky" {
      buildGoModule = args:
        super.buildGoModule (args
          // {
            vendorHash = "sha256-h1CkvI7M1kt2Ix3D8+gDl97CFElV+0/9Eram1burOaM=";
            version = "0.23";
            src = pkgs.fetchFromGitHub {
              owner = "0xERR0R";
              repo = "blocky";
              rev = "dece894bd6d62205f2ec69379850e2a526667c8d";
              sha256 = "NVtZCqxvsTaz5EDTMCxsubR5V6ESE2KozOXriFdnNWE=";
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
          default = ["1.1.1.2" "1.0.0.2"];
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
