{ lib, config, pkgs, nixpkgs, modulesPath, ... }:

with lib;

let
  cloudNode = "localhost";
  localNode = "striker.arsfeld.net";
  domain = "arsfeld.dev";
  email = "arsfeld@gmail.com";
in
{
  services.caddy = {
    enable = true;
    email = email;
    ca = "https://acme-staging-v02.api.letsencrypt.org/directory";
    virtualHosts = {
      "files.${domain}:8888" = {
        extraConfig = "reverse_proxy ${localNode}:8334";
      };
    };
  };
}