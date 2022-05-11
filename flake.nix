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

    colmena.url = "github:zhaofengli/colmena";
    colmena.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    utils,
    nixpkgs,
    colmena,
    nixos-generators,
    home-manager,
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
      colmena = {
        meta = {
          nixpkgs = import nixpkgs {
            system = "x86_64-linux";
          };
        };

        battlestar = {
          deployment = {
            targetHost = "battlestar";
            buildOnTarget = true;
          };
          imports = [
            ./machines/battlestar/configuration.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.arosenfeld = import ./home/home.nix;
            }
          ];
        };

        oracle = {
          nixpkgs.system = "aarch64-linux";
          deployment = {
            targetHost = "oracle";
            buildOnTarget = true;
          };
          imports = [
            ./machines/oracle/configuration.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.arosenfeld = import ./home/home.nix;
            }
          ];
        };

        striker = {
          deployment = {
            allowLocalDeployment = true;
            targetHost = "striker";
          };
          imports = [
            ./machines/striker/configuration.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.arosenfeld = import ./home/home.nix;
            }
          ];
        };

        storage = {
          deployment = {
            allowLocalDeployment = true;
            targetHost = "storage";
          };
          imports = [
            ./machines/storage/configuration.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.arosenfeld = import ./home/home.nix;
            }
          ];
        };

        # r2s = {
        #   deployment = {
        #     targetHost = "192.168.31.180";
        #   };
        #   imports = [
        #     ./machines/r2s/configuration.nix
        #     home-manager.nixosModules.home-manager
        #     {
        #       home-manager.useGlobalPkgs = true;
        #       home-manager.useUserPackages = true;
        #       home-manager.users.arosenfeld = import ./home/home.nix;
        #     }
        #   ];
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
    };
}
