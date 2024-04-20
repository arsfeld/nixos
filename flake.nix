{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/073a26ea454df46ae180207c752ef8c6f6e6ea85";
    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    agenix.url = "github:ryantm/agenix";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";
    haumea.url = "github:nix-community/haumea";
    haumea.inputs.nixpkgs.follows = "nixpkgs";
    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    attic.url = "github:zhaofengli/attic";
    attic.inputs.nixpkgs.follows = "nixpkgs";
    nixos-flake.url = "github:srid/nixos-flake";
  };

  outputs = {self, ...} @ inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} ({moduleWithSystem, ...}: {
      debug = true;

      imports = [
        inputs.devshell.flakeModule
        inputs.treefmt-nix.flakeModule
        #inputs.colmena-flake.flakeModules.default
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
          };

        nixosConfigurations = {
          storage = self.lib.mkLinuxSystem ./hosts/storage/configuration.nix;
          raider = self.lib.mkLinuxSystem ./hosts/raider/configuration.nix;
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
          };
        };

        checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;

        # nixosModules = {
        #   base = [
        #     ./profiles/core/default.nix
        #     ./profiles/users/root.nix
        #     ./profiles/users/arosenfeld.nix
        #     ./profiles/users/media.nix
        #     ./profiles/networking/tailscale.nix
        #   ];
        # };
      };

      # flake.colmena = {
      #   meta = {
      #     nixpkgs = import inputs.nixpkgs {
      #       system = "x86_64-linux";
      #       config.allowUnfree = true;
      #     };
      #     specialArgs.suites = self.nixosSuites;
      #   };

      #   defaults = moduleWithSystem (
      #     perSystem @ {
      #       inputs',
      #       self',
      #     }: {lib, ...}: {
      #       imports =
      #         [
      #           inputs.agenix.nixosModules.default
      #           inputs.home-manager.nixosModules.home-manager
      #           {
      #             home-manager.useGlobalPkgs = true;
      #             home-manager.useUserPackages = true;
      #             home-manager.users.arosenfeld = import ./home/home.nix;
      #           }
      #         ]
      #         ++ lib.attrValues self.nixosModules;
      #       _module.args = {
      #         inputs = perSystem.inputs';
      #         self = self // perSystem.self'; # to preserve original attributes in self like outPath
      #       };
      #       deployment = {
      #         buildOnTarget = false;
      #       };
      #     }
      #   );
      # } // builtins.mapAttrs (name: value: { imports = value._module.args.modules; }) self.nixosConfigurations;

      # micro = {...}: {
      #   imports = [
      #     ./hosts/micro/configuration.nix
      #   ];
      # };

      # cloud = {...}: {
      #   nixpkgs.system = "aarch64-linux";
      #   imports = [
      #     inputs.attic.nixosModules.atticd
      #     ./hosts/cloud/configuration.nix
      #   ];
      # };

      # storage = {...}: {
      #   imports = [
      #     ./common/modules/systemd-email-notify.nix
      #     ./hosts/storage/configuration.nix
      #   ];
      # };

      # raider-nixos = {...}: {
      #   deployment = {
      #     targetHost = "raider-nixos";
      #   };
      #   imports = [
      #     ./hosts/raider/configuration.nix
      #   ];
      # };

      # r2s = {...}: {
      #   nixpkgs.system = "aarch64-linux";
      #   imports = [
      #     ./common/modules/fake-hwclock.nix
      #     ./hosts/r2s/configuration.nix
      #   ];
      # };
    });

  # homeConfigurations."linux" = let
  #   system = "x86_64-linux";
  #   pkgs = nixpkgs.legacyPackages.${system};
  # in
  #   home-manager.lib.homeManagerConfiguration {
  #     pkgs = nixpkgs.legacyPackages.${system};
  #     modules = [
  #       ./home/home.nix
  #     ];
  #   };

  # homeConfigurations."aarch64" = let
  #   system = "aarch64-linux";
  #   pkgs = nixpkgs.legacyPackages.${system};
  # in
  #   home-manager.lib.homeManagerConfiguration {
  #     pkgs = nixpkgs.legacyPackages.${system};
  #     modules = [
  #       ./home/home.nix
  #     ];
  #   };

  # homeConfigurations.m1 = let
  #   system = "aarch64-darwin";
  # in
  #   home-manager.lib.homeManagerConfiguration {
  #     pkgs = nixpkgs.legacyPackages.${system};
  #     modules = [
  #       ./home/home.nix
  #     ];
  #   };
}
