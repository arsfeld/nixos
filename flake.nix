{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    utils.url = "github:numtide/flake-utils";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixos-vscode-server.url = "github:msteen/nixos-vscode-server";
    nixos-vscode-server.flake = false;

    colmena.url = "github:zhaofengli/colmena/stable";
    colmena.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs @ {
    self,
    home-manager,
    nixpkgs,
    utils,
    colmena,
    nixos-generators,
    nixos-vscode-server,
    ...
  }: let
    username = "arosenfeld";
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
  in
    utils.lib.eachSystem supportedSystems (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [colmena.overlay];
      };
    in rec {
      devShell = pkgs.mkShell {
        buildInputs = with pkgs; [
          pkgs.home-manager
          pkgs.colmena
          pkgs.alejandra
        ];
      };
    })
    // {
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
            overlays = [
              (import ./pkgs/caddy.nix)
            ];
          };
        };

        oracle = {
          nixpkgs.system = "aarch64-linux";
          deployment = {
            targetHost = "oracle";
            buildOnTarget = true;
            tags = ["cloud"];
          };
          imports =
            [
              ./machines/oracle/configuration.nix
            ]
            ++ homeFeatures;
        };

        aws-br = {
          nixpkgs.system = "aarch64-linux";
          deployment = {
            targetHost = "15.229.29.57";
            buildOnTarget = true;
            tags = ["cloud"];
          };
          imports =
            [
              ./machines/aws-br/configuration.nix
            ]
            ++ homeFeatures;
        };

        storage = {
          deployment = {
            allowLocalDeployment = true;
            buildOnTarget = true;
            targetHost = "storage";
          };
          imports =
            [
              ./machines/storage/configuration.nix
            ]
            ++ homeFeatures;
        };

        r2s = {
          nixpkgs.system = "aarch64-linux";
          deployment = {
            targetHost = "r2s";
            buildOnTarget = true;
          };
          imports =
            [
              ./machines/r2s/configuration.nix
            ]
            ++ homeFeatures;
        };
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

      homeConfigurations."${username}-linux" = let
        system = "x86_64-linux";
      in
        home-manager.lib.homeManagerConfiguration {
          # Specify the path to your home configuration here
          configuration = import ./home/home.nix;

          inherit system username;
          homeDirectory = nixpkgs.lib.mkForce "/home/${username}";
          # Update the state version as needed.
          # See the changelog here:
          # https://nix-community.github.io/home-manager/release-notes.html#sec-release-21.05
          stateVersion = "22.05";

          # Optionally use extraSpecialArgs
          # to pass through arguments to home.nix
        };

      homeConfigurations.${username} = let
        system = "aarch64-darwin";
      in
        home-manager.lib.homeManagerConfiguration {
          # Specify the path to your home configuration here
          configuration = import ./home/home.nix;

          inherit system username;
          homeDirectory = nixpkgs.lib.mkForce "/Users/${username}";
          # Update the state version as needed.
          # See the changelog here:
          # https://nix-community.github.io/home-manager/release-notes.html#sec-release-21.05
          stateVersion = "22.05";

          # Optionally use extraSpecialArgs
          # to pass through arguments to home.nix
        };
    };
}
