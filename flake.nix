{

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    colmena = {
      meta = {
        nixpkgs = import nixpkgs {
          system = "x86_64-linux";
        };
      };

      oracle = {
        nixpkgs.system = "aarch64-linux";
        deployment = {
          targetHost = "oracle.arsfeld.net";
          targetUser = "root";
        };
        imports = [ ./oracle/configuration.nix ];
      };


      virgon = {
        deployment = {
          targetHost = "virgon.arsfeld.net";
          targetUser = "root";
        };
        imports = [ ./virgon/configuration.nix ];
      };

      striker = {
        deployment = {
          allowLocalDeployment = true;
          targetHost = "striker.arsfeld.net";
          targetUser = "root";
        };
        imports = [ ./striker/configuration.nix ];
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
