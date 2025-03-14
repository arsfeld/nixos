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
  # See full reference at https://devenv.sh/reference/options/
}
