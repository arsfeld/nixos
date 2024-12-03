{
  inputs = {
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";
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
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
    flatpaks.url = "github:GermanBread/declarative-flatpak/stable-v3";
    tsnsrv.url = "github:boinkor-net/tsnsrv";

    nixos-cosmic = {
      url = "github:lilyinstarlight/nixos-cosmic";
      #inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {self, ...} @ inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} ({moduleWithSystem, ...}: {
      imports = [
        inputs.devshell.flakeModule
        #inputs.treefmt-nix.flakeModule
        inputs.process-compose-flake.flakeModule
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
        process-compose."default" = {
          settings = {
            processes = {
              attic-push.command = "attic watch-store oci:system";
            };
          };
        };

        # treefmt = {
        #   programs.alejandra.enable = true;
        #   flakeFormatter = true;
        #   projectRootFile = "flake.nix";
        # };

        devshells.default = {pkgs, ...}: {
          commands = [
            {package = inputs'.agenix.packages.default;}
            {package = inputs'.disko.packages.default;}
          ];
          packages = [
            pkgs.lix
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
        lib = let
          commonModules = [
            inputs.agenix.nixosModules.default
            inputs.flatpaks.nixosModules.declarative-flatpak
            inputs.tsnsrv.nixosModules.default
            inputs.home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = false;
              home-manager.backupFileExtension = "bak";
              home-manager.users.arosenfeld = import ./home/home.nix;
            }
          ];
        in rec {
          mkLinuxSystem = mods:
            inputs.nixpkgs.lib.nixosSystem {
              # Arguments to pass to all modules.
              specialArgs = {inherit self inputs;};
              modules = commonModules ++ mods;
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
            base = [core.default core.virt users.root users.arosenfeld users.media networking.tailscale];
            server = with networking; [acme mail];
            backups = with backup; [common];
            sites = with sites; [arsfeld-one arsfeld-dev rosenfeld-one];
            storage = with suites; flatten [base server backups sites];
            raider = with suites; flatten [base core.desktop];
            g14 = with suites; flatten [base core.desktop];
            cloud = with suites; flatten [base server backups sites];
            core-vm = with suites; flatten [base];
            hpe = with suites; flatten [base];
          };

        nixosConfigurations = {
          storage = self.lib.mkLinuxSystem [
            inputs.disko.nixosModules.disko
            ./hosts/storage/configuration.nix
          ];
          raider = self.lib.mkLinuxSystem [
            inputs.nixos-cosmic.nixosModules.default
            ./hosts/raider/configuration.nix
          ];
          cloud = self.lib.mkLinuxSystem [./hosts/cloud/configuration.nix];
          cloud-br = self.lib.mkLinuxSystem [./hosts/cloud-br/configuration.nix];
          r2s = self.lib.mkLinuxSystem [./hosts/r2s/configuration.nix];
          raspi3 = self.lib.mkLinuxSystem [./hosts/raspi3/configuration.nix];
          core = self.lib.mkLinuxSystem [./hosts/core/configuration.nix];
          g14 = self.lib.mkLinuxSystem [
            inputs.nixos-cosmic.nixosModules.default
            ./hosts/g14/configuration.nix
          ];
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
