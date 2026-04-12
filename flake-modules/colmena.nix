{
  self,
  inputs,
  ...
}: {
  # Colmena deployment configuration
  flake.colmena = let
    # Function to create colmena host configuration
    mkColmenaHost = hostName: let
      # Check if host has a disko config file
      hasDisko = builtins.pathExists ../hosts/${hostName}/disko-config.nix;
      enableHM = !(builtins.elem hostName self.lib.lightHosts);
      isUnstable = builtins.elem hostName self.unstableHosts;
      hmModules =
        if isUnstable
        then self.lib.homeManagerModulesFor inputs.home-manager-unstable
        else self.lib.homeManagerModules;
    in {
      deployment = {
        targetHost = "${hostName}.bat-boa.ts.net";
        targetUser = "root";
        buildOnTarget = false;
      };
      imports =
        self.lib.baseModules
        ++ (
          if enableHM
          then hmModules
          else []
        )
        ++ (
          if hasDisko
          then [inputs.disko.nixosModules.disko]
          else []
        )
        ++ [
          ../hosts/${hostName}/configuration.nix
        ];
    };

    # Find aarch64 hosts by checking their configurations
    aarch64Hosts =
      builtins.filter (
        name: let
          hostConfig = self.nixosConfigurations.${name}.config;
          system = hostConfig.nixpkgs.hostPlatform.system or "x86_64-linux";
        in
          system == "aarch64-linux"
      )
      self.hosts;

    # Define nixpkgs overrides: aarch64 hosts for cross-compilation, unstable hosts for latest packages
    nodeNixpkgs =
      builtins.listToAttrs (
        map (hostName: {
          name = hostName;
          value = import inputs.nixpkgs {
            system = "aarch64-linux";
            overlays = self.lib.overlays;
          };
        })
        aarch64Hosts
      )
      // builtins.listToAttrs (
        map (hostName: {
          name = hostName;
          value = import inputs.nixpkgs-unstable {
            system = "x86_64-linux";
            overlays = self.lib.overlays;
          };
        })
        self.unstableHosts
      );
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
    // (builtins.listToAttrs (
      map (hostName: {
        name = hostName;
        value = mkColmenaHost hostName;
      })
      self.hosts
    ));
}
