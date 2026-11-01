{config, ...}: {
  # Published for discovery (`nix flake show`). These modules assume this
  # flake's `base` module and overlays; they are not built to work in another
  # flake.
  flake.nixosModules = config.flake.modules.nixos;
}
