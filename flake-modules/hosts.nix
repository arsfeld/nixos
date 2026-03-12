{
  self,
  inputs,
  ...
}: {
  flake = {
    # Auto-discover all hosts from the hosts/ directory
    hosts = let
      # Load all host directories
      hostDirs = builtins.readDir ../hosts;
      # Filter for directories that have configuration.nix
      validHosts =
        inputs.nixpkgs.lib.filterAttrs (
          name: type: type == "directory" && builtins.pathExists ../hosts/${name}/configuration.nix
        )
        hostDirs;
    in
      builtins.attrNames validHosts;

    nixosConfigurations = builtins.listToAttrs (
      map (
        hostName: let
          # Check if host has a disko config file
          hasDisko = builtins.pathExists ../hosts/${hostName}/disko-config.nix;
        in {
          name = hostName;
          value = self.lib.mkLinuxSystem {
            enableHomeManager = !(builtins.elem hostName self.lib.lightHosts);
            mods =
              (
                if hasDisko
                then [inputs.disko.nixosModules.disko]
                else []
              )
              ++ [
                ../hosts/${hostName}/configuration.nix
              ];
          };
        }
      )
      self.hosts
    );
  };
}
