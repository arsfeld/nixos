{
  configurations.nixos.galactica.module = {config, ...}: let
    vars = config.media.config;
  in {
    constellation.forgejo-runner = {
      url = "https://forgejo.${vars.domain}";
      capacity = 3;
    };
  };
}
