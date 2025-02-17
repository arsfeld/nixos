{ self, config, pkgs, ... }: {
  age.secrets.github-runner-token.file = "${self}/secrets/github-runner-token.age";

  # For vscode
  nixpkgs.config.permittedInsecurePackages = [
    "nodejs-16.20.2"
  ];

  services.openvscode-server = {
    enable = true;
    user = "arosenfeld";
    host = "0.0.0.0";
    withoutConnectionToken = true;
  };

  # services.github-runners.cloud = {
  #   enable = false;
  #   extraLabels = ["nixos" "cloud" "aarch64"];
  #   tokenFile = config.age.secrets.github-runner-token.path;
  #   url = "https://github.com/arsfeld/nixos";
  # };
} 