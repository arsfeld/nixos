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
          immich-pixel-sync-test =
            inputs.nixpkgs.legacyPackages.${system}.runCommand "immich-pixel-sync-test" {
              nativeBuildInputs = [inputs.nixpkgs.legacyPackages.${system}.python3];
            } ''
              cp ${../modules/constellation/immich-pixel-sync}/*.py .
              python3 -m unittest discover -v -s . -p 'test_*.py'
              touch $out
            '';
        }
    )
    inputs.deploy-rs.lib;
}
