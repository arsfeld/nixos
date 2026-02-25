{
  self,
  inputs,
  ...
}: {
  # Deploy-rs configuration
  flake.deploy = let
    mkDeploy = hostName: let
      # Get the system from the nixosConfiguration
      hostConfig = self.nixosConfigurations.${hostName}.config;
      system = hostConfig.nixpkgs.hostPlatform.system or "x86_64-linux";
    in {
      hostname = "${hostName}.bat-boa.ts.net";
      fastConnection = true;
      remoteBuild = hostName == "cloud"; # Enable remote build for cloud (aarch64)
      profiles.system.path =
        inputs.deploy-rs.lib.${system}.activate.nixos
        self.nixosConfigurations.${hostName};
    };
  in {
    sshUser = "root";
    autoRollback = false;
    magicRollback = false;
    nodes = builtins.listToAttrs (
      map (hostName: {
        name = hostName;
        value = mkDeploy hostName;
      })
      self.hosts
    );
  };
}
