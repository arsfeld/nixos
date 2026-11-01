{self, ...}: {
  # Buildable system closures keyed by host. This deliberately *is*
  # nixosConfigurations, so `just deploy`, the CI matrix and weekly-deploy all
  # realise identical derivation paths — which is why substitution always hits.
  #
  # Do not reintroduce a second evaluation that calls `import inputs.nixpkgs`
  # itself: that loses the flake revision and yields `…-26.05pre-git`
  # derivations nothing has ever built. That is what broke colmena.
  flake.deployTargets =
    builtins.mapAttrs (_: c: c.config.system.build.toplevel) self.nixosConfigurations;
}
