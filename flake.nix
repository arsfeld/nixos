{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05"; # Core nixpkgs - stable 25.05
    nixos-generators.url = "github:nix-community/nixos-generators"; # System image generators (ISO, SD card, etc.)
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";
    disko.url = "github:nix-community/disko"; # Declarative disk partitioning
    disko.inputs.nixpkgs.follows = "nixpkgs";
    agenix.url = "github:ryantm/agenix"; # Age-based secret management
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager/release-25.05"; # User environment management
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    deploy-rs.url = "github:serokell/deploy-rs"; # Remote deployment tool
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts"; # Flake framework for modular development
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    haumea.url = "github:nix-community/haumea"; # File tree loader for Nix
    haumea.inputs.nixpkgs.follows = "nixpkgs";
    devenv.url = "github:cachix/devenv"; # Development environment manager
    devenv.inputs.nixpkgs.follows = "nixpkgs";
    nix-flatpak.url = "github:gmodena/nix-flatpak"; # Flatpak support for NixOS
    tsnsrv.url = "github:arsfeld/tsnsrv"; # Tailscale name server
    tsnsrv.inputs.nixpkgs.follows = "nixpkgs";
    nix-index-database.url = "github:nix-community/nix-index-database"; # Faster command-not-found
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";
    eh5.url = "github:EHfive/flakes"; # EH5's flake collection (fake-hwclock module)
    eh5.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {self, ...} @ inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} ({moduleWithSystem, ...}: {
      imports = [
        inputs.devenv.flakeModule
      ];

      systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];

      perSystem = {
        config,
        self',
        inputs',
        pkgs,
        system,
        ...
      }: {
        devShells.default = inputs.devenv.lib.mkShell {
          inherit inputs pkgs;
          modules = [
            ./devenv.nix
          ];
        };

        legacyPackages.homeConfigurations.arosenfeld = inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            inputs.nix-index-database.hmModules.nix-index
            ./home/home.nix
            {
              # Specific to standalone home-manager
              nixpkgs.config = {
                allowUnfree = true;
                android_sdk.accept_license = true;
              };
            }
          ];
        };
      };

      flake = {
        lib = let
          commonModules = inputs.nixpkgs.lib.flatten [
            inputs.agenix.nixosModules.default
            inputs.nix-flatpak.nixosModules.nix-flatpak
            inputs.tsnsrv.nixosModules.default
            inputs.home-manager.nixosModules.home-manager
            {
              home-manager.sharedModules = [
                inputs.nix-index-database.hmModules.nix-index
              ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = false;
              home-manager.backupFileExtension = "bak";
              home-manager.users.arosenfeld = import ./home/home.nix;
            }
            {
              nixpkgs.overlays = [
                (import ./overlays/python-packages.nix)
                # Load packages from ./packages directory using haumea
                (
                  final: prev: let
                    packages = inputs.haumea.lib.load {
                      src = ./packages;
                      loader = inputs.haumea.lib.loaders.callPackage;
                      transformer = inputs.haumea.lib.transformers.liftDefault;
                      inputs = {
                        inherit (final) lib pkgs;
                      };
                    };
                  in
                    prev // packages
                )
              ];
            }
            # Load all modules from the modules directory
            (let
              getAllValues = set: let
                recurse = value:
                  if builtins.isAttrs value
                  then builtins.concatLists (map recurse (builtins.attrValues value))
                  else [value];
              in
                recurse set;
              modules = inputs.haumea.lib.load {
                src = ./modules;
                loader = inputs.haumea.lib.loaders.path;
              };
            in
              getAllValues modules)
          ];
          baseModules = inputs.nixpkgs.lib.flatten [
            inputs.agenix.nixosModules.default
            inputs.nix-flatpak.nixosModules.nix-flatpak
            inputs.tsnsrv.nixosModules.default
            {
              nixpkgs.overlays = [
                (import ./overlays/python-packages.nix)
                # Load packages from ./packages directory using haumea
                (
                  final: prev: let
                    packages = inputs.haumea.lib.load {
                      src = ./packages;
                      loader = inputs.haumea.lib.loaders.callPackage;
                      transformer = inputs.haumea.lib.transformers.liftDefault;
                      inputs = {
                        inherit (final) lib pkgs;
                      };
                    };
                  in
                    prev // packages
                )
              ];
            }
            # Load all modules from the modules directory
            (let
              getAllValues = set: let
                recurse = value:
                  if builtins.isAttrs value
                  then builtins.concatLists (map recurse (builtins.attrValues value))
                  else [value];
              in
                recurse set;
              modules = inputs.haumea.lib.load {
                src = ./modules;
                loader = inputs.haumea.lib.loaders.path;
              };
            in
              getAllValues modules)
          ];

          homeManagerModules = [
            inputs.home-manager.nixosModules.home-manager
            {
              home-manager.sharedModules = [
                inputs.nix-index-database.hmModules.nix-index
              ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = false;
              home-manager.backupFileExtension = "bak";
              home-manager.users.arosenfeld = import ./home/home.nix;
            }
          ];
        in {
          mkLinuxSystem = {
            mods,
            includeHomeManager ? true,
          }:
            inputs.nixpkgs.lib.nixosSystem {
              # Arguments to pass to all modules.
              specialArgs = {inherit self inputs;};
              modules =
                baseModules
                ++ (
                  if includeHomeManager
                  then homeManagerModules
                  else []
                )
                ++ mods;
            };
        };

        nixosConfigurations = {
          storage = self.lib.mkLinuxSystem {
            mods = [
              inputs.disko.nixosModules.disko
              ./hosts/storage/configuration.nix
            ];
          };
          cloud = self.lib.mkLinuxSystem {
            mods = [./hosts/cloud/configuration.nix];
          };
          router = self.lib.mkLinuxSystem {
            mods = [
              inputs.disko.nixosModules.disko
              ./hosts/router/configuration.nix
            ];
          };
          r2s = self.lib.mkLinuxSystem {
            mods = [
              inputs.eh5.nixosModules.fake-hwclock
              ./hosts/r2s/configuration.nix
            ];
          };
          raspi3 = self.lib.mkLinuxSystem {
            mods = [./hosts/raspi3/configuration.nix];
          };
        };

        deploy = let
          # Host-specific deployment overrides (only specify what differs from defaults)
          deployOverrides = {
            storage = {}; # Use all defaults
            router = {}; # Use all defaults
            cloud = {
              system = "aarch64-linux";
              remoteBuild = true;
            };
            r2s.system = "aarch64-linux";
            raspi3.system = "aarch64-linux";
          };

          mkDeploy = hostName: overrides: let
            defaults = {
              hostname = "${hostName}.bat-boa.ts.net";
              system = "x86_64-linux";
              fastConnection = true;
              remoteBuild = false;
            };
            config = defaults // overrides;
          in {
            inherit (config) hostname fastConnection remoteBuild;
            profiles.system.path = inputs.deploy-rs.lib.${config.system}.activate.nixos self.nixosConfigurations.${hostName};
          };
        in {
          sshUser = "root";
          autoRollback = false;
          magicRollback = false;
          nodes = builtins.mapAttrs mkDeploy deployOverrides;
        };

        packages.aarch64-linux = {
          raspi3 = inputs.nixos-generators.nixosGenerate {
            pkgs = inputs.nixpkgs.legacyPackages.aarch64-linux;
            modules = [
              ./hosts/raspi3/configuration.nix
            ];
            format = "sd-aarch64";
          };
        };

        checks =
          builtins.mapAttrs (
            system: deployLib:
              deployLib.deployChecks self.deploy
              // {
                router-test = inputs.nixpkgs.legacyPackages.${system}.nixosTest (import ./tests/router-test.nix {inherit self inputs;});
                router-test-production = inputs.nixpkgs.legacyPackages.${system}.nixosTest (import ./tests/router-test-production.nix);
              }
          )
          inputs.deploy-rs.lib;

        # Router testing configurations
        nixosConfigurations.router-test = inputs.nixpkgs.lib.nixosSystem {
          specialArgs = {inherit self inputs;};
          modules = [
            ./tests/router-container-test.nix
          ];
        };

        # Testing configurations and packages
        packages.x86_64-linux = {
          # Add r2s image from above to ensure we have all the entries
          inherit (self.packages.aarch64-linux) raspi3;

          # Router QEMU test
          router-test = inputs.nixpkgs.legacyPackages.x86_64-linux.callPackage ./tests/router-qemu-test.nix {};
        };
      };
    });
}
