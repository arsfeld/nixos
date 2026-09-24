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
            cp ${../hosts/galactica/services/immich-pixel-sync}/*.py .
            python3 -m unittest discover -v -s . -p 'test_*.py'
            touch $out
          '';
      }
      // inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
        # cylon-link is cross-compiled from x86_64; its checks are too.
        cylon-link-boot = import ../hosts/cylon-link/boot/test.nix {
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        };
        cylon-link-config = import ../hosts/cylon-link/config-test.nix {
          inherit self;
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        };

        # The media lower layers (media.gateway.services, media.containers)
        # may only be written by modules/media/; services.nix asserts it.
        # Probe galactica with a stray write to each and require that the
        # assertion fires and names the probe. Reads config.assertions rather
        # than tryEval'ing the toplevel, so an unrelated eval error cannot
        # pass for the guard working.
        media-lower-layers-guarded = let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;
          probed = self.nixosConfigurations.galactica.extendModules {
            modules = [
              {
                _file = "media-guard-probe";
                media.gateway.services.probe.port = 1;
                media.containers.probe = {};
              }
            ];
          };
          fires = path:
            lib.any (a: !a.assertion && lib.hasPrefix path a.message && lib.hasInfix "media-guard-probe" a.message)
            probed.config.assertions;
          missing = lib.filter (p: !fires p) ["media.gateway.services" "media.containers"];
        in
          if missing == []
          then pkgs.runCommand "media-lower-layers-guarded" {} "touch $out"
          else throw "media lower-layer guard did not fire for: ${lib.concatStringsSep ", " missing}";
      };
  };
}
