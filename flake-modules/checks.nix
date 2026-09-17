{
  self,
  inputs,
  ...
}: {
  perSystem = {system, ...}: {
    checks =
      {
        router-test = inputs.nixpkgs.legacyPackages.${system}.testers.nixosTest (
          import ../tests/router-test.nix {inherit self inputs;}
        );
        router-test-production = inputs.nixpkgs.legacyPackages.${system}.testers.nixosTest (
          import ../tests/router-test-production.nix
        );
        harmonia-cache-test = inputs.nixpkgs.legacyPackages.${system}.testers.nixosTest (
          import ../tests/harmonia-cache-test.nix {inherit self inputs;}
        );
        blackbird-audio-control-test = import ../tests/blackbird-audio-control-test.nix {
          inherit self inputs system;
        };
        immich-pixel-sync-test =
          inputs.nixpkgs.legacyPackages.${system}.runCommand "immich-pixel-sync-test" {
            nativeBuildInputs = [inputs.nixpkgs.legacyPackages.${system}.python3];
          } ''
            cp ${../modules/constellation/immich-pixel-sync}/*.py .
            python3 -m unittest discover -v -s . -p 'test_*.py'
            touch $out
          '';
      }
      // inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
        # cylon-link is cross-compiled from x86_64; its checks are too.
        cylon-link-boot = import ../hosts/cylon-link/boot/test.nix {
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        };
      };
  };
}
