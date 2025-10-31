{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05"; # Core nixpkgs - stable 25.05
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable-small"; # Unstable packages for latest versions
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*"; # Determinate Nix
    nixos-generators.url = "github:nix-community/nixos-generators"; # System image generators (ISO, SD card, etc.)
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";
    disko.url = "github:nix-community/disko"; # Declarative disk partitioning
    disko.inputs.nixpkgs.follows = "nixpkgs";
    ragenix.url = "github:arsfeld/ragenix/add-decrypt-flag"; # Rust-based age secret management (faster and more reliable)
    ragenix.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager/release-25.05"; # User environment management
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    deploy-rs.url = "github:serokell/deploy-rs"; # Remote deployment tool
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts"; # Flake framework for modular development
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    haumea.url = "github:nix-community/haumea"; # File tree loader for Nix
    haumea.inputs.nixpkgs.follows = "nixpkgs";
    git-hooks.url = "github:cachix/git-hooks.nix"; # Git hooks framework
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    nix-flatpak.url = "github:gmodena/nix-flatpak"; # Flatpak support for NixOS
    tsnsrv.url = "github:arsfeld/tsnsrv"; # Tailscale name server
    tsnsrv.inputs.nixpkgs.follows = "nixpkgs";
    nix-index-database.url = "github:nix-community/nix-index-database"; # Faster command-not-found
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";
    harmonia.url = "github:nix-community/harmonia"; # Binary cache server
    harmonia.inputs.nixpkgs.follows = "nixpkgs";
    eh5.url = "github:EHfive/flakes"; # EH5's flake collection (fake-hwclock module)
    eh5.inputs.nixpkgs.follows = "nixpkgs";
    vpn-confinement.url = "github:Maroka-chan/VPN-Confinement"; # VPN namespace confinement for services
    vpn-confinement.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {self, ...} @ inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} ({moduleWithSystem, ...}: {
      imports = [];

      systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];

      perSystem = {
        config,
        self',
        inputs',
        pkgs,
        system,
        ...
      }: {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            # Provide Go 1.25+ from nixpkgs-unstable for packages that need it (must come first)
            (final: prev: let
              system = final.stdenv.hostPlatform.system;
            in {
              go_1_25 = inputs.nixpkgs-unstable.legacyPackages.${system}.go;
              buildGo125Module = final.buildGoModule.override {
                go = inputs.nixpkgs-unstable.legacyPackages.${system}.go;
              };
            })
            (import ./overlays/python-packages.nix)
            # Caddy with Tailscale OAuth plugin (must come after buildGo125Module is available)
            (final: prev: {
              caddy-tailscale = final.callPackage ./packages/caddy-tailscale {};
            })
          ];
        };
        formatter = pkgs.alejandra;
        checks = {
          pre-commit-check = inputs.git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              alejandra.enable = true;
              gptcommit = {
                enable = false;
                name = "gptcommit";
                entry = "${pkgs.gptcommit}/bin/gptcommit prepare-commit-msg";
                language = "system";
                stages = ["prepare-commit-msg"];
                always_run = true;
                pass_filenames = false;
                args = ["--commit-msg-file"];
              };
            };
          };
        };
        devShells.default = pkgs.mkShell {
          inherit (config.checks.pre-commit-check) shellHook;
          buildInputs = with pkgs;
            [
              # Nix tools
              alejandra
              attic-client
              colmena
              deploy-rs
              disko
              git
              jq
              just
              openssl
              inputs.ragenix.packages."${pkgs.stdenv.system}".default
              inputs.disko.packages."${pkgs.stdenv.system}".default

              # Python tools
              black
              python3Packages.mkdocs
              python3Packages.mkdocs-material
              python3Packages.mkdocs-awesome-pages-plugin
              python3Packages.mkdocs-mermaid2-plugin
              python3Packages.mike
              python3Packages.pymdown-extensions

              # Git commit tools
              gptcommit
            ]
            ++ config.checks.pre-commit-check.enabledPackages;
        };

        # Expose packages loaded via haumea
        packages = inputs.haumea.lib.load {
          src = ./packages;
          loader = inputs.haumea.lib.loaders.callPackage;
          inputs = {inherit pkgs;};
          transformer = inputs.haumea.lib.transformers.liftDefault;
        };

        legacyPackages.homeConfigurations.arosenfeld = inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            inputs.nix-index-database.homeModules.nix-index
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
          # Define packages loading function once
          loadPackages = pkgs: let
            loaded = inputs.haumea.lib.load {
              src = ./packages;
              loader = inputs.haumea.lib.loaders.callPackage;
              inputs = {inherit pkgs;};
            };
          in
            builtins.mapAttrs (
              name: value:
                if value ? default
                then value.default
                else value
            )
            loaded;

          # Common overlays used everywhere
          overlays = [
            # Provide Go 1.25+ from nixpkgs-unstable for packages that need it (must come first)
            (final: prev: let
              system = final.stdenv.hostPlatform.system;
            in {
              go_1_25 = inputs.nixpkgs-unstable.legacyPackages.${system}.go;
              buildGo125Module = final.buildGoModule.override {
                go = inputs.nixpkgs-unstable.legacyPackages.${system}.go;
              };
            })
            (import ./overlays/python-packages.nix)
            # Caddy with Tailscale OAuth plugin (must come after buildGo125Module is available)
            (final: prev: {
              caddy-tailscale = final.callPackage ./packages/caddy-tailscale {};
            })
            # Load packages from ./packages directory using haumea
            (final: prev: loadPackages final)
          ];

          baseModules = inputs.nixpkgs.lib.flatten [
            inputs.ragenix.nixosModules.default
            inputs.determinate.nixosModules.default
            inputs.nix-flatpak.nixosModules.nix-flatpak
            inputs.harmonia.nixosModules.harmonia
            inputs.tsnsrv.nixosModules.default
            inputs.vpn-confinement.nixosModules.default
            {
              nixpkgs.overlays = overlays;
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
                inputs.nix-index-database.homeModules.nix-index
              ];
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = false;
              home-manager.backupFileExtension = "bak";
              home-manager.users.arosenfeld = import ./home/home.nix;
            }
          ];
        in {
          inherit loadPackages overlays baseModules homeManagerModules;

          mkLinuxSystem = {mods}:
            inputs.nixpkgs.lib.nixosSystem {
              # Arguments to pass to all modules.
              specialArgs = {inherit self inputs;};
              modules =
                baseModules
                ++ homeManagerModules
                ++ mods;
            };
        };

        # Auto-discover all hosts from the hosts/ directory
        hosts = let
          # Load all host directories
          hostDirs = builtins.readDir ./hosts;
          # Filter for directories that have configuration.nix
          validHosts =
            inputs.nixpkgs.lib.filterAttrs (
              name: type:
                type == "directory" && builtins.pathExists ./hosts/${name}/configuration.nix
            )
            hostDirs;
        in
          builtins.attrNames validHosts;

        nixosConfigurations = builtins.listToAttrs (map (hostName: let
            # Check if host has a disko config file
            hasDisko = builtins.pathExists ./hosts/${hostName}/disko-config.nix;
          in {
            name = hostName;
            value = self.lib.mkLinuxSystem {
              mods =
                (
                  if hasDisko
                  then [inputs.disko.nixosModules.disko]
                  else []
                )
                ++ [./hosts/${hostName}/configuration.nix];
            };
          })
          self.hosts);

        # Deploy-rs configuration
        deploy = let
          mkDeploy = hostName: let
            # Get the system from the nixosConfiguration
            hostConfig = self.nixosConfigurations.${hostName}.config;
            system = hostConfig.nixpkgs.hostPlatform.system or "x86_64-linux";
          in {
            hostname = "${hostName}.bat-boa.ts.net";
            fastConnection = true;
            remoteBuild = hostName == "cloud"; # Enable remote build for cloud (aarch64)
            profiles.system.path = inputs.deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.${hostName};
          };
        in {
          sshUser = "root";
          autoRollback = false;
          magicRollback = false;
          nodes = builtins.listToAttrs (map (hostName: {
              name = hostName;
              value = mkDeploy hostName;
            })
            self.hosts);
        };

        packages.aarch64-linux = {
          raspi3 = inputs.nixos-generators.nixosGenerate {
            system = "aarch64-linux";
            modules =
              self.lib.baseModules
              ++ [
                ./hosts/raspi3/configuration.nix
              ];
            specialArgs = {inherit self inputs;};
            format = "sd-aarch64";
          };
          octopi = inputs.nixos-generators.nixosGenerate {
            system = "aarch64-linux";
            modules =
              self.lib.baseModules
              ++ [
                ./hosts/octopi/configuration.nix
              ];
            specialArgs = {inherit self inputs;};
            format = "sd-aarch64";
          };
        };

        # Colmena deployment configuration
        colmena = let
          # Function to create colmena host configuration
          mkColmenaHost = hostName: let
            # Check if host has a disko config file
            hasDisko = builtins.pathExists ./hosts/${hostName}/disko-config.nix;
          in {
            deployment = {
              targetHost = "${hostName}.bat-boa.ts.net";
              targetUser = "root";
              buildOnTarget = false;
            };
            imports =
              self.lib.baseModules
              ++ self.lib.homeManagerModules
              ++ (
                if hasDisko
                then [inputs.disko.nixosModules.disko]
                else []
              )
              ++ [
                ./hosts/${hostName}/configuration.nix
              ];
          };

          # Find aarch64 hosts by checking their configurations
          aarch64Hosts = builtins.filter (name: let
            hostConfig = self.nixosConfigurations.${name}.config;
            system = hostConfig.nixpkgs.hostPlatform.system or "x86_64-linux";
          in
            system == "aarch64-linux")
          self.hosts;

          # Define nixpkgs for each aarch64 host to enable cross-compilation
          nodeNixpkgs = builtins.listToAttrs (map (hostName: {
              name = hostName;
              value = import inputs.nixpkgs {
                system = "aarch64-linux";
                overlays = self.lib.overlays;
              };
            })
            aarch64Hosts);
        in
          {
            meta = {
              nixpkgs = import inputs.nixpkgs {
                system = "x86_64-linux";
                overlays = self.lib.overlays;
              };
              inherit nodeNixpkgs;
              specialArgs = {inherit self inputs;};
            };
          }
          // (builtins.listToAttrs (map (hostName: {
              name = hostName;
              value = mkColmenaHost hostName;
            })
            self.hosts));

        checks =
          builtins.mapAttrs (
            system: deployLib:
              deployLib.deployChecks self.deploy
              // {
                router-test = inputs.nixpkgs.legacyPackages.${system}.nixosTest (import ./tests/router-test.nix {inherit self inputs;});
                router-test-production = inputs.nixpkgs.legacyPackages.${system}.nixosTest (import ./tests/router-test-production.nix);
                harmonia-cache-test = inputs.nixpkgs.legacyPackages.${system}.nixosTest (import ./tests/harmonia-cache-test.nix {inherit self inputs;});
              }
          )
          inputs.deploy-rs.lib;

        # Testing configurations and packages
        packages.x86_64-linux = {
          # Add ARM images from above to ensure we have all the entries
          inherit (self.packages.aarch64-linux) raspi3 octopi;

          # Router QEMU test
          router-test = inputs.nixpkgs.legacyPackages.x86_64-linux.callPackage ./tests/router-qemu-test.nix {};

          # Custom kexec image with Tailscale for nixos-anywhere
          kexec-tailscale = inputs.nixos-generators.nixosGenerate {
            pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
            modules = [./kexec-tailscale.nix];
            format = "kexec-bundle";
          };
        };
      };
    });
}
