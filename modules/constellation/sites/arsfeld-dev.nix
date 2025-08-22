{
  lib,
  config,
  ...
}: let
  domain = "arsfeld.dev";
in {
  options.constellation.sites.arsfeld-dev = {
    enable = lib.mkEnableOption "arsfeld-dev";
  };

  config = lib.mkIf config.constellation.sites.arsfeld-dev.enable {
    security.acme.certs."${domain}" = {
      extraDomainNames = ["*.${domain}"];
    };

    services.caddy.virtualHosts = {
      "${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          # Serve specific .well-known files for verification
          handle /.well-known/org.flathub.VerifiedApps.txt {
            respond "${builtins.readFile ./well-known/org.flathub.VerifiedApps.txt}"
          }

          # Redirect all other requests to blog
          handle {
            redir https://blog.${domain}
          }
        '';
      };

      "www.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          redir https://blog.${domain}{uri}
        '';
      };

      # blog.${domain} is now handled directly by constellation.blog module
      # Supabase instances are now handled dynamically by services.supabase

      "reel.${domain}" = {
        useACMEHost = domain;
        extraConfig = ''
          root * ${./reel}
          file_server
        '';
      };
    };
  };
}
