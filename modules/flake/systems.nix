{inputs, ...}: {
  # flake.modules.<class>.<name>: the features hosts import
  # (docs/superpowers/specs/2026-10-31-dendritic-restructure-design.md).
  imports = [inputs.flake-parts.flakeModules.modules];

  systems = [
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-darwin"
  ];
}
