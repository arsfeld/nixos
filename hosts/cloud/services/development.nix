{
  self,
  config,
  pkgs,
  ...
}: let
  vars = config.media.config;
in {
  sops.secrets.github-runner-token = {};
  sops.secrets.forgejo-runner-token = {};

  # services.github-runners.cloud = {
  #   enable = false;
  #   extraLabels = ["nixos" "cloud" "aarch64"];
  #   tokenFile = config.sops.secrets.github-runner-token.path;
  #   url = "https://github.com/arsfeld/nixos";
  # };

  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    instances.cloud = {
      enable = false; # TODO: Set a valid token in forgejo-runner-token.age to enable
      name = "cloud";
      url = "https://forgejo.${vars.domain}";
      tokenFile = config.sops.secrets.forgejo-runner-token.path;
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
