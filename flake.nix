{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";
    disko.url = github:nix-community/disko;
    disko.inputs.nixpkgs.follows = "nixpkgs";
    nixos-nftables-firewall.url = "github:thelegy/nixos-nftables-firewall";
    nixos-nftables-firewall.inputs.nixpkgs.follows = "nixpkgs";
    agenix.url = "github:ryantm/agenix";
    utils.url = "github:numtide/flake-utils";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixos-mailserver.url = "gitlab:simple-nixos-mailserver/nixos-mailserver";
    nixos-mailserver.inputs.nixpkgs.follows = "nixpkgs";
    colmena.url = "github:zhaofengli/colmena";
    flake-parts.url = "github:hercules-ci/flake-parts";
    haumea.url = "github:nix-community/haumea";
    devshell.url = "github:numtide/devshell";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = {
    self,
    flake-parts,
    haumea,
    devshell,
    home-manager,
    nixpkgs,
    utils,
    disko,
    agenix,
    nixos-generators,
    nixos-nftables-firewall,
    nixos-hardware,
    nixos-mailserver,
    deploy-rs,
    treefmt-nix,
    ...
  } @ inputs:
    flake-parts.lib.mkFlake {inherit inputs;} ({moduleWithSystem, ...}: {
      # homeFeatures = [
      #   home-manager.nixosModules.home-manager
      #   {
      #     home-manager.useGlobalPkgs = true;
      #     home-manager.useUserPackages = true;
      #     home-manager.users.arosenfeld = import ./home/home.nix;
      #   }
      # ];

      imports = [
        devshell.flakeModule
        treefmt-nix.flakeModule
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
        packages = {inherit pkgs;}; #import ./pkgs {inherit pkgs;};

        treefmt = {
          programs.alejandra.enable = true;
          flakeFormatter = true;
          projectRootFile = "flake.nix";
        };

        devshells.default = {pkgs, ...}: {
          commands = [
            {package = pkgs.nixUnstable;}
            {package = inputs'.agenix.packages.default;}
            {package = inputs'.colmena.packages.colmena;}
          ];
        };
      };

      flake.nixosProfiles = haumea.lib.load {
        src = ./profiles;
        loader = haumea.lib.loaders.path;
      };
      flake.nixosSuites = let
        suites = self.nixosSuites;
      in
        with self.nixosProfiles; {
          base = [core.default users.root users.arosenfeld users.media];
          network = with networking; [acme blocky mail tailscale];
          backups = with backup; [common];
          #sites = with sites; ["arsfeld.one" "arsfeld.dev" "rosenfeld.blog" "rosenfeld.one"];
          micro = with suites; nixpkgs.lib.flatten [base network backups];
        };

      flake.colmena = {
        meta = {
          nixpkgs = import nixpkgs {
            system = "x86_64-linux";
            config.allowUnfree = true;
          };
          specialArgs.suites = self.nixosSuites;
        };

        defaults = moduleWithSystem (
          perSystem @ {
            inputs',
            self',
          }: {lib, ...}: {
            imports =
              [
                agenix.nixosModules.default
                # home-manager.nixosModules.home-manager
                # {
                #      home-manager.useGlobalPkgs = true;
                #      home-manager.useUserPackages = true;
                #      home-manager.users.arosenfeld = import ./home/home.nix;
                # }
              ]
              ++ lib.attrValues self.nixosModules;
            _module.args = {
              inputs = perSystem.inputs';
              self = self // perSystem.self'; # to preserve original attributes in self like outPath
            };
            deployment = {
              buildOnTarget = true;
              targetUser = null;
            };
          }
        );

        micro = {...}: {
          imports = [
            ./hosts/micro/configuration.nix
          ];
        };

        cloud = {...}: {
          nixpkgs.system = "aarch64-linux";
          imports = [
            ./hosts/cloud/configuration.nix
          ];
        };

        storage = {
          imports = [
            ./hosts/storage/configuration.nix
          ];
        };

        raider = {
          deployment = {
            targetHost = "raider";
            #allowLocalDeployment = true;
            tags = ["local"];
          };
          imports = [
            agenix.nixosModules.default
            ./machines/raider/configuration.nix
          ];
        };

        r2s = {
          nixpkgs.system = "aarch64-linux";
          deployment = {
            targetHost = "r2s";
          };
          imports = [
            ./common/modules/fake-hwclock.nix
            ./machines/r2s/configuration.nix
          ];
        };
      };
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
