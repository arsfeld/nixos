{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/073a26ea454df46ae180207c752ef8c6f6e6ea85";
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
    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    attic.url = "github:zhaofengli/attic";
    nixos-flake.url = "github:srid/nixos-flake";
  };

  outputs = {self, ...} @ inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} ({moduleWithSystem, ...}: {
      imports = [
        inputs.devshell.flakeModule
        inputs.treefmt-nix.flakeModule
        inputs.nixos-flake.flakeModule
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
        #packages = {inherit pkgs;}; #import ./pkgs {inherit pkgs;};

        treefmt = {
          programs.alejandra.enable = true;
          flakeFormatter = true;
          projectRootFile = "flake.nix";
        };

        devshells.default = {pkgs, ...}: {
          commands = [
            {package = pkgs.nixUnstable;}
            {package = inputs'.agenix.packages.default;}
            #{package = inputs'.colmena.packages.colmena;}
          ];
          packages = [
            pkgs.just
            pkgs.attic-client
            pkgs.alejandra
            pkgs.deploy-rs
            pkgs.colmena
          ];
        };

        legacyPackages.homeConfigurations.arosenfeld = inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            ./home/home.nix
          ];
        };
      };

      flake = {
        lib = rec {
          mkLinuxSystem = mod:
            inputs.nixpkgs.lib.nixosSystem {
              # Arguments to pass to all modules.
              specialArgs = {inherit self inputs;};
              modules = [
                inputs.agenix.nixosModules.default
                inputs.home-manager.nixosModules.home-manager
                {
                  home-manager.useGlobalPkgs = true;
                  home-manager.useUserPackages = true;
                  home-manager.users.arosenfeld = import ./home/home.nix;
                }
                mod
              ];
            };
        };

        nixosProfiles = inputs.haumea.lib.load {
          src = ./profiles;
          loader = inputs.haumea.lib.loaders.path;
        };

        nixosSuites = let
          flatten = inputs.nixpkgs.lib.flatten;
          suites = self.nixosSuites;
        in
          with self.nixosProfiles; {
            base = [core.default users.root users.arosenfeld users.media networking.tailscale];
            network = with networking; [acme blocky mail];
            backups = with backup; [common];
            sites = with sites; [arsfeld-one arsfeld-dev rosenfeld-blog rosenfeld-one];
            storage = with suites; flatten [base core.virt network backups sites];
            #micro = with suites; flatten [base network backups];
            raider = with suites; flatten [base];
            cloud = with suites; flatten [base core.virt network backups sites];
          };

        nixosConfigurations = {
          storage = self.lib.mkLinuxSystem ./hosts/storage/configuration.nix;
          raider = self.lib.mkLinuxSystem ./hosts/raider/configuration.nix;
          cloud = self.lib.mkLinuxSystem ./hosts/cloud/configuration.nix;
        };

        deploy = {
          sshUser = "root";
          nodes = {
            storage = {
              hostname = "storage";
              profiles.system.path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.storage;
            };
            raider = {
              hostname = "raider-nixos";
              profiles.system.path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.raider;
            };
            cloud = {
              hostname = "cloud";
              remoteBuild = true;
              profiles.system.path = inputs.deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.cloud;
            };
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
