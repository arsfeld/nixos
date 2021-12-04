{

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-21.11";
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
      modules = [ ./configuration.nix ];
    };

    nixosConfigurations.striker = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [ ./configuration.nix ];
    };
  };
}
