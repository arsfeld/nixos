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
    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
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
        process-compose."default" = {
          settings = {
            processes = {
              attic-push.command = "attic watch-store system";
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
                # Add packages overlay
                (
                  final: prev: {
                    send-email-event = final.callPackage ./packages/send-email-event {inherit final prev;};
                  }
                )
              ];
            }
            # Load all modules from the modules directory
            (let
              modules = inputs.haumea.lib.load {
                src = ./modules;
                loader = inputs.haumea.lib.loaders.path;
              };
            in
              builtins.attrValues modules)
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
            cloud = with suites; flatten [base core.netdata server backups sites];
            core-vm = with suites; flatten [base core.netdata];
            hpe = with suites; flatten [base core.netdata];
          };

        nixosConfigurations = {
          storage = self.lib.mkLinuxSystem [
            inputs.disko.nixosModules.disko
            ./hosts/storage/configuration.nix
          ];
          raider = self.lib.mkLinuxSystem [
            ./hosts/raider/configuration.nix
          ];
          cloud = self.lib.mkLinuxSystem [./hosts/cloud/configuration.nix];
          cloud-br = self.lib.mkLinuxSystem [./hosts/cloud-br/configuration.nix];
          r2s = self.lib.mkLinuxSystem [
            inputs.eh5.nixosModules.fake-hwclock
            ./hosts/r2s/configuration.nix
          ];
          raspi3 = self.lib.mkLinuxSystem [./hosts/raspi3/configuration.nix];
          core = self.lib.mkLinuxSystem [./hosts/core/configuration.nix];
          g14 = self.lib.mkLinuxSystem [
            inputs.disko.nixosModules.disko
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
