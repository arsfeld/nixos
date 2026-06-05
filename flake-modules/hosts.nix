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

    # Hosts that use nixpkgs-unstable instead of stable nixpkgs
    unstableHosts = ["raider"];

    # Deployment tiers. Tier 1 hosts are always on and should always be
    # deployed. Consumed by colmena (deployment.tags, e.g. `colmena apply
    # --on @tier1`) and documented in README.md / CLAUDE.md.
    tiers = {
      tier1 = ["basestar" "galactica" "raider"];
    };

    # CI build matrix, derived from the discovered hosts with auto-detected
    # platforms. Consumed by .github/workflows/build.yml via `nix eval`.
    ciMatrix =
      map (hostName: {
        host = hostName;
        platform = self.nixosConfigurations.${hostName}.config.nixpkgs.hostPlatform.system;
      })
      self.hosts;

    nixosConfigurations = builtins.listToAttrs (
      map (
        hostName: let
          # Check if host has a disko config file
          hasDisko = builtins.pathExists ../hosts/${hostName}/disko-config.nix;
          isUnstable = builtins.elem hostName self.unstableHosts;
        in {
          name = hostName;
          value = self.lib.mkLinuxSystem {
            enableHomeManager = !(builtins.elem hostName self.lib.lightHosts);
            nixpkgsInput =
              if isUnstable
              then inputs.nixpkgs-unstable
              else inputs.nixpkgs;
            homeManagerInput =
              if isUnstable
              then inputs.home-manager-unstable
              else inputs.home-manager;
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
