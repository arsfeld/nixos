{...}: let
  domain = "arsfeld.dev";
in {
  config = {
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
    };
  };
}
