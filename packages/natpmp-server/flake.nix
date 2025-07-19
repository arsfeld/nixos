{
  description = "NAT-PMP server for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        natpmp-server = pkgs.callPackage ./default.nix { };
      in
      {
        packages = {
          default = natpmp-server;
          natpmp-server = natpmp-server;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            go
            gopls
            gotools
            go-tools
            python3
          ];
        };

        apps.default = {
          type = "app";
          program = "${natpmp-server}/bin/natpmp-server";
        };
      }
    ) // {
      nixosModules.default = ./module.nix;
      
      # Example NixOS configuration for testing
      nixosConfigurations.test-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          self.nixosModules.default
          {
            boot.isContainer = true;
            
            networking.useDHCP = false;
            networking.interfaces.eth0.ipv4.addresses = [{
              address = "10.0.0.1";
              prefixLength = 24;
            }];
            
            services.natpmp-server = {
              enable = true;
              externalInterface = "eth0";
              listenInterface = "eth0";
            };
            
            system.stateVersion = "24.05";
          }
        ];
      };
    };
}