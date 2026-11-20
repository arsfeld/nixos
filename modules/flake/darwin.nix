# The Macs: configurations.darwin.<name> becomes darwinConfigurations.<name>,
# switched on the Mac itself with
#   sudo darwin-rebuild switch --flake github:arsfeld/nixos#<name>
# They are not in ciMatrix (no darwin runners) and not in `just deploy`.
{
  config,
  lib,
  self,
  inputs,
  ...
}: {
  options.configurations.darwin = lib.mkOption {
    description = "macOS hosts. Each becomes darwinConfigurations.<name>.";
    default = {};
    type = lib.types.lazyAttrsOf (lib.types.submodule {
      options.module = lib.mkOption {
        type = lib.types.deferredModule;
        description = "The Mac's nix-darwin configuration.";
      };
    });
  };

  config.flake.darwinConfigurations = lib.mapAttrs (name: h:
    inputs.nix-darwin.lib.darwinSystem {
      specialArgs = {
        inherit inputs;
        darwinHost = name;
      };
      modules =
        [
          inputs.determinate.darwinModules.default
          {
            nixpkgs.hostPlatform = "aarch64-darwin";
            nixpkgs.overlays = self.lib.overlays;
            nixpkgs.config = self.lib.macNixpkgsConfig;
            home-manager.sharedModules = [self.lib.macHomeModule];
          }
          config.flake.modules.darwin.mac
          h.module
        ]
        ++ self.lib.homeManagerModulesFor inputs.home-manager.darwinModules.home-manager;
    })
  config.configurations.darwin;
}
