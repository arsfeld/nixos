{config, ...}: let
  vars = config.media.config;
in {
  constellation.forgejo-runner = {
    enable = true;
    url = "https://forgejo.${vars.domain}";
    capacity = 3;
  };
}
