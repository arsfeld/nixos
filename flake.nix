{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";
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
    attic.url = "github:zhaofengli/attic";
    attic.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs @ {
    self,
    home-manager,
    nixpkgs,
    utils,
    disko,
    agenix,
    attic,
    nixos-generators,
    nixos-nftables-firewall,
    ...
  }: let
    inherit (self) outputs;
  in {
    nixosConfigurations = {
      live = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ({
            pkgs,
            modulesPath,
            ...
          }: {
            imports = [
              ./common/users.nix
            ];
            systemd.services.sshd.wantedBy = pkgs.lib.mkForce ["multi-user.target"];
            isoImage.squashfsCompression = "gzip -Xcompression-level 1";
          })
        ];
      };
      router = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          nixos-nftables-firewall.nixosModules.default
          ./machines/router/configuration.nix
        ];
      };
    };
    colmena = let
      homeFeatures = [
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.arosenfeld = import ./home/home.nix;
        }
      ];
    in {
      meta = {
        nixpkgs = import nixpkgs {
          system = "x86_64-linux";
        };
        specialArgs = {inherit inputs outputs;};
      };

      micro = {
        deployment = {
          targetHost = "micro";
          tags = ["cloud"];
        };
        imports =
          [
            agenix.nixosModules.default
            ./machines/micro/configuration.nix
          ]
          ++ homeFeatures;
      };

      cloud = {
        nixpkgs.system = "aarch64-linux";
        deployment = {
          allowLocalDeployment = true;
          targetHost = "cloud";
          tags = ["cloud"];
        };
        imports =
          [
            agenix.nixosModules.default
            attic.nixosModules.atticd
            ./machines/cloud/configuration.nix
          ]
          ++ homeFeatures;
      };

      router = {
        deployment = {
          targetHost = "router";
        };
        imports =
          [
            disko.nixosModules.disko
            nixos-nftables-firewall.nixosModules.default
            ./machines/router/configuration.nix
          ]
          ++ homeFeatures;
      };

      G14 = {
        deployment = {
          targetHost = null;
          #allowLocalDeployment = true;
          tags = ["local"];
        };
        imports =
          [
            ./machines/g14/configuration.nix
          ]
          ++ homeFeatures;
      };

      storage = {
        deployment = {
          targetHost = "storage";
          tags = ["local"];
        };
        imports =
          [
            agenix.nixosModules.default
            ./common/modules/systemd-email-notify.nix
            ./machines/storage/configuration.nix
          ]
          ++ homeFeatures;
      };

      striker = {
        deployment = {
          targetHost = "striker";
          tags = ["local"];
        };
        imports =
          [
            agenix.nixosModules.default
            ./machines/striker/configuration.nix
          ]
          ++ homeFeatures;
      };

      pegasus = {
        deployment = {
          targetHost = "pegasus";
          tags = ["local"];
        };
        imports =
          [
            ./machines/pegasus/configuration.nix
          ]
          ++ homeFeatures;
      };

      raspi3 = {
        deployment = {
          targetHost = "raspi3";
          tags = ["local"];
        };
        imports =
          [
            ./machines/raspi3/configuration.nix
          ]
          ++ homeFeatures;
      };

      # r2s = {
      #   nixpkgs.system = "aarch64-linux";
      #   deployment = {
      #     targetHost = "r2s";
      #   };
      #   imports =
      #     [
      #       ./machines/r2s/configuration.nix
      #     ]
      #     ++ homeFeatures;
      # };
    };

    packages.x86_64-linux = {
      proxmox = nixos-generators.nixosGenerate {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        modules = [
          # you can include your own nixos configuration here, i.e.
          # ./configuration.nix
          ./common/common.nix
          ./common/users.nix
        ];
        format = "proxmox";
      };
    };

    homeConfigurations."linux" = let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
      home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        modules = [
          ./home/home.nix
        ];
      };

    homeConfigurations."aarch64" = let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
      home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        modules = [
          ./home/home.nix
        ];
      };

    homeConfigurations.m1 = let
      system = "aarch64-darwin";
    in
      home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.${system};
        modules = [
          ./home/home.nix
        ];
      };
  };
}
