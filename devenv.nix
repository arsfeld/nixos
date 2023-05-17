{
  pkgs,
  inputs,
  ...
}: {
  # https://devenv.sh/packages/
  packages = with pkgs; [
    colmena
    home-manager
    alejandra
    nil
    inputs.agenix.packages."${pkgs.system}".default
  ];

  # https://devenv.sh/languages/
  languages.nix.enable = true;

  # https://devenv.sh/pre-commit-hooks/
  pre-commit.hooks.alejandra.enable = true;

  devcontainer.enable = true;
}
