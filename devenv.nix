{pkgs, ...}: {
  # https://devenv.sh/packages/
  packages = [pkgs.colmena pkgs.home-manager pkgs.alejandra];

  # https://devenv.sh/languages/
  languages.nix.enable = true;

  # https://devenv.sh/pre-commit-hooks/
  pre-commit.hooks.alejandra.enable = true;
}
