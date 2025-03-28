{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-generators.url = "github:nix-community/nixos-generators";
    disko.url = "github:nix-community/disko";
    agenix.url = "github:ryantm/agenix";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    haumea.url = "github:nix-community/haumea";
    devenv.url = "github:cachix/devenv";
    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    nix-flatpak.url = "github:gmodena/nix-flatpak";
    tsnsrv.url = "github:boinkor-net/tsnsrv";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    eh5 = {
      url = "github:EHfive/flakes";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {self, ...} @ inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} ({moduleWithSystem, ...}: {
      imports = [
        inputs.devenv.flakeModule
      ];

      systems = ["x86_64-linux" "aarch64-linux"];

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
                # This should work, but it doesn't
                # (
                #   final: prev: let
                #   packages =  (inputs.haumea.lib.load {
                #     src = ./packages;
                #     loader = inputs.haumea.lib.loaders.callPackage;
                #     transformer = inputs.haumea.lib.transformers.liftDefault;
                #   }); in prev // builtins.trace packages packages
                # )
                # Add packages overlay
                (
                  final: prev: let
                    packages = {
                      send-email-event = final.callPackage ./packages/send-email-event {};
                      check-stock = final.callPackage ./packages/check-stock {};
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
        in rec {
          mkLinuxSystem = mods:
            inputs.nixpkgs.lib.nixosSystem {
              # Arguments to pass to all modules.
              specialArgs = {inherit self inputs;};
              modules = commonModules ++ mods;
            };
        };

        nixosConfigurations = {
          storage = self.lib.mkLinuxSystem [
            inputs.disko.nixosModules.disko
            ./hosts/storage/configuration.nix
          ];
          cloud = self.lib.mkLinuxSystem [./hosts/cloud/configuration.nix];
          cloud-br = self.lib.mkLinuxSystem [./hosts/cloud-br/configuration.nix];
          r2s = self.lib.mkLinuxSystem [
            inputs.eh5.nixosModules.fake-hwclock
            ./hosts/r2s/configuration.nix
          ];
          raspi3 = self.lib.mkLinuxSystem [./hosts/raspi3/configuration.nix];
          core = self.lib.mkLinuxSystem [./hosts/core/configuration.nix];
          hpe = self.lib.mkLinuxSystem [
            inputs.disko.nixosModules.disko
            ./hosts/hpe/configuration.nix
          ];
        };

        deploy = import ./deploy.nix {inherit self inputs;};

        packages.aarch64-linux = {
          raspi3 = inputs.nixos-generators.nixosGenerate {
            pkgs = inputs.nixpkgs.legacyPackages.aarch64-linux;
            modules = [
              ./hosts/raspi3/configuration.nix
            ];
            format = "sd-aarch64";
          };
        };

        checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;
      };

      # r2s = {...}: {
      #   nixpkgs.system = "aarch64-linux";
      #   imports = [
      #     ./common/modules/fake-hwclock.nix
      #     ./hosts/r2s/configuration.nix
      #   ];
      # };
    });
}
