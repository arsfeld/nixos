{inputs, ...}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    # The OCI provider ships no darwin build in nixpkgs, and infrastructure is
    # only ever applied from a Linux workstation. Guarding here keeps the flake
    # evaluable on aarch64-darwin, which `systems` still lists.
    #
    # The guard is nested inside `packages` rather than wrapped around this
    # module's whole return value: this repo's `dev.nix` re-defines
    # `_module.args.pkgs`, which makes `pkgs` part of the perSystem config
    # fixpoint. flake-parts' module-syntax unification forces the top-level
    # shape of every perSystem module's return value up front, so guarding at
    # that level forces `pkgs` before it is available and deadlocks in
    # infinite recursion. Nesting the guard one level down keeps the top-level
    # shape (`{packages = <thunk>;}`) independent of `pkgs`.
    packages = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      # The generated OpenTofu configuration. `just tf` links this into
      # infra/.work as config.tf.json.
      infra-config = inputs.terranix.lib.terranixConfiguration {
        inherit pkgs;
        modules = [../infra];
      };

      # OpenTofu with both providers baked into a local plugin mirror, so
      # `tofu init` never contacts a registry and provider versions advance
      # with flake.lock rather than with a lock file in a scratch directory.
      # `just tf` resolves this path explicitly instead of trusting PATH:
      # an ambient tofu would silently fall back to fetching providers.
      tofu = pkgs.opentofu.withPlugins (p: [
        p.oracle_oci
        p.cloudflare_cloudflare
      ]);
    };
  };
}
