{
  self,
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;
in {
  age.secrets.github-runner-token.file = "${self}/secrets/github-runner-token.age";
  age.secrets.forgejo-runner-token.file = "${self}/secrets/forgejo-runner-token.age";

  # services.github-runners.cloud = {
  #   enable = false;
  #   extraLabels = ["nixos" "cloud" "aarch64"];
  #   tokenFile = config.age.secrets.github-runner-token.path;
  #   url = "https://github.com/arsfeld/nixos";
  # };

  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    instances.cloud = {
      enable = true;
      name = "cloud";
      url = "https://forgejo.${vars.domain}";
      tokenFile = config.age.secrets.forgejo-runner-token.path;
      labels = [
        "ubuntu-latest:docker://node:20-bookworm"
        "nix:docker://nixos/nix:latest"
        "native:host"
      ];
      settings = {
        runner.capacity = 2;
        container.network = "host";
      };
    };
  };
}
