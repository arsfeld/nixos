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
        raider-fan-control-test =
          inputs.nixpkgs.legacyPackages.${system}.runCommand "raider-fan-control-test" {
            nativeBuildInputs = [inputs.nixpkgs.legacyPackages.${system}.python3];
          } ''
            cp ${../hosts/raider/fan-control}/*.py .
            python3 -m unittest discover -v -s . -p 'test_*.py'
            touch $out
          '';
      }
      // inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
        # cylon-link is cross-compiled from x86_64; its checks are too.
        cylon-link-boot = import ../hosts/cylon-link/boot/test.nix {
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        };
        pantheon-dock-stacks-test = inputs.nixpkgs.legacyPackages.${system}.testers.nixosTest (
          import ../tests/pantheon-dock-stacks-test.nix
        );
        cylon-link-config = import ../hosts/cylon-link/config-test.nix {
          inherit self;
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        };

        # The heating policy's generated Home Assistant templates, rendered
        # outside HA by a harness that mimics the extensions they use.
        heating-policy-test = let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          hass = self.nixosConfigurations.galactica.config.services.home-assistant.config;
          config = pkgs.writeText "heating.json" (builtins.toJSON {
            template = hass.template;
            input_boolean = hass.input_boolean or {};
            input_number = hass.input_number or {};
            automation = hass."automation heating";
          });
        in
          pkgs.runCommand "heating-policy-test" {
            nativeBuildInputs = [(pkgs.python3.withPackages (ps: [ps.jinja2]))];
            HEATING_CONFIG = config;
          } ''
            cp ${../hosts/galactica/services/home-assistant-heating}/*.py .
            python3 -m unittest discover -v -s . -p 'test_*.py'
            touch $out
          '';

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

        # Every media container is hardened by default (see
        # docs/superpowers/specs/2026-10-25-container-hardening-design.md).
        # Probe galactica with one service per case and compare the
        # generated capability and security flags exactly.
        media-container-hardening = let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;
          other = "docker.io/example/other:latest";
          probed = self.nixosConfigurations.galactica.extendModules {
            modules = [
              {
                media.services = {
                  hprobe-lsio = {
                    port = 1;
                    container = {};
                  };
                  hprobe-other = {
                    port = 2;
                    image = other;
                    container = {};
                  };
                  hprobe-caps = {
                    port = 3;
                    image = other;
                    container.hardening.caps = ["NET_ADMIN"];
                  };
                  hprobe-optout = {
                    port = 4;
                    container.hardening.enable = false;
                  };
                  hprobe-priv = {
                    port = 5;
                    container.privileged = true;
                  };
                };
              }
            ];
          };
          flags = n:
            lib.filter (o: lib.hasPrefix "--cap-" o || lib.hasPrefix "--security-opt" o)
            probed.config.virtualisation.oci-containers.containers.${n}.extraOptions;
          wrap = caps: ["--cap-drop=ALL"] ++ map (c: "--cap-add=${c}") caps ++ ["--security-opt=no-new-privileges"];
          expect = {
            hprobe-lsio = wrap ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID" "KILL"];
            hprobe-other = wrap [];
            hprobe-caps = wrap ["NET_ADMIN"];
            hprobe-optout = [];
            hprobe-priv = [];
          };
          wrong = lib.filter (n: flags n != expect.${n}) (lib.attrNames expect);
        in
          if wrong == []
          then pkgs.runCommand "media-container-hardening" {} "touch $out"
          else throw "hardening flags wrong for: ${lib.concatMapStringsSep "; " (n: "${n} = ${builtins.toJSON (flags n)}") wrong}";
      };
  };
}
