{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: {
  # https://devenv.sh/packages/
  packages = with pkgs; [
    alejandra
    attic-client
    black
    colmena
    deploy-rs
    disko
    git
    jq
    just
    openssl
    inputs.agenix.packages."${pkgs.stdenv.system}".default
    inputs.disko.packages."${pkgs.stdenv.system}".default

    # MkDocs and dependencies
    python3Packages.mkdocs
    python3Packages.mkdocs-material
    python3Packages.mkdocs-mermaid2-plugin
    python3Packages.mkdocs-awesome-pages-plugin
    python3Packages.mike
    python3Packages.pymdown-extensions
  ];
  # See full reference at https://devenv.sh/reference/options/

  git-hooks.hooks = {
    alejandra.enable = true;
    gptcommit.enable = true;
  };
}
