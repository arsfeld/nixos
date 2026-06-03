{
  self,
  inputs,
  ...
}: {
  flake.checks =
    builtins.mapAttrs (
      system: deployLib:
        deployLib.deployChecks self.deploy
        // {
          router-test = inputs.nixpkgs.legacyPackages.${system}.testers.nixosTest (
            import ../tests/router-test.nix {inherit self inputs;}
          );
          router-test-production = inputs.nixpkgs.legacyPackages.${system}.testers.nixosTest (
            import ../tests/router-test-production.nix
          );
          harmonia-cache-test = inputs.nixpkgs.legacyPackages.${system}.testers.nixosTest (
            import ../tests/harmonia-cache-test.nix {inherit self inputs;}
          );
        }
    )
    inputs.deploy-rs.lib;
}
