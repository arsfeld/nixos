{
  lib,
  config,
  pkgs,
  nixpkgs,
  modulesPath,
  ...
}:
with lib; let
  domain = "arsfeld.dev";
  email = "arsfeld@gmail.com";
  dataDir = "/mnt/media";
in {
  users.users.caddy.extraGroups = ["acme"];

  security.acme = {
    acceptTerms = true;
  };

  networking.firewall.allowedTCPPorts = [22 80 443];

  services.caddy = {
    enable = true;
    email = email;
    package = pkgs.xcaddy;

    globalConfig = ''
      order authenticate before respond
      order authorize before reverse_proxy

      security {
        local identity store localdb {
          realm local
          path /var/lib/caddy/.config/caddy/users.json
        }
        authentication portal myportal {
          enable identity store localdb
          cookie lifetime 604800 # 7 days in seconds
          ui
          transform user {
            match email ${email}
            action add role authp/user
          }
        }
        authorization policy admin_dev {
            set auth url https://auth.arsfeld.dev
            allow roles authp/user
        }
        authorization policy admin_one {
            set auth url https://auth.arsfeld.one
            allow roles authp/user
        }
      }
    '';
  };
}
