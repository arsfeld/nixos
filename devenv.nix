{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: {
  # https://devenv.sh/packages/
  packages = [
    pkgs.git
    pkgs.just
    pkgs.attic-client
    pkgs.alejandra
    pkgs.deploy-rs
    pkgs.colmena
    pkgs.disko
    inputs.agenix.packages."${pkgs.stdenv.system}".default
    inputs.disko.packages."${pkgs.stdenv.system}".default
  ];

  # Python environment for MkDocs
  languages.python = {
    enable = true;
    package = pkgs.python3;
    uv.enable = true;
  };
  # See full reference at https://devenv.sh/reference/options/
}
