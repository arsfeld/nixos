{

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators }: {
    colmena = {
      meta = {
        nixpkgs = import nixpkgs {
          system = "x86_64-linux";
        };
      };

      battlestar = {
        deployment = {
          targetHost = "battlestar.arsfeld.org";
        };
        imports = [ ./battlestar/configuration.nix ];
      };

      oracle = {
        nixpkgs.system = "aarch64-linux";
        deployment = {
          targetHost = "oracle.arsfeld.net";
          buildOnTarget = true;
        };
        imports = [ ./oracle/configuration.nix ];
      };

      striker = {
        deployment = {
          allowLocalDeployment = true;
          targetHost = "striker.arsfeld.net";
        };
        imports = [ ./striker/configuration.nix ];
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

    nixosConfigurations.striker = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./striker/configuration.nix ];
    };
    
    nixosConfigurations.virgon = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./virgon/configuration.nix ];
    };

    nixosConfigurations.oracle = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [ ./oracle/configuration.nix ];
    };
    
    nixosConfigurations.libran = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [ ./libran/configuration.nix ];
    };
  };
}
