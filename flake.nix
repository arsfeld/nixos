{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix.url = "github:ryantm/agenix";

    utils.url = "github:numtide/flake-utils";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs @ {
    self,
    home-manager,
    nixpkgs,
    utils,
    agenix,
    nixos-generators,
    ...
  }: {
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
      };

      micro = {
        deployment = {
          targetHost = "micro";
          tags = ["cloud"];
          buildOnTarget = true;
        };
        imports =
          [
            agenix.nixosModules.default
            ./machines/micro/configuration.nix
          ]
          ++ homeFeatures;
      };

      G14 = {
        deployment = {
          targetHost = null;
          allowLocalDeployment = true;
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
          buildOnTarget = true;
          tags = ["local"];
        };
        imports =
          [
            agenix.nixosModules.default
            ./machines/storage/configuration.nix
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
          ./home/vscode-ssh-fix.nix
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
