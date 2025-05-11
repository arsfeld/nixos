{
  self,
  config,
  pkgs,
  ...
}: {
  age.secrets.github-runner-token.file = "${self}/secrets/github-runner-token.age";

  # services.github-runners.cloud = {
  #   enable = false;
  #   extraLabels = ["nixos" "cloud" "aarch64"];
  #   tokenFile = config.age.secrets.github-runner-token.path;
  #   url = "https://github.com/arsfeld/nixos";
  # };
}
