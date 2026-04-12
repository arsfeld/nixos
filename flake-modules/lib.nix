{
  self,
  inputs,
  ...
}: {
  flake.lib = let
    # Define packages loading function once
    loadPackages = pkgs: let
      loaded = inputs.haumea.lib.load {
        src = ../packages;
        loader = inputs.haumea.lib.loaders.callPackage;
        inputs = {inherit pkgs;};
      };
    in
      builtins.mapAttrs (name: value:
        if value ? default
        then value.default
        else value)
      loaded;

    # Common overlays used everywhere
    overlays = [
      (import ../overlays/python-packages.nix)
      # Load packages from ./packages directory using haumea
      (final: prev: loadPackages final)
    ];

    baseModules = inputs.nixpkgs.lib.flatten [
      inputs.sops-nix.nixosModules.sops
      inputs.determinate.nixosModules.default
      inputs.nix-flatpak.nixosModules.nix-flatpak
      inputs.harmonia.nixosModules.harmonia
      inputs.vpn-confinement.nixosModules.default
      inputs.niri.nixosModules.niri
      {niri-flake.cache.enable = inputs.nixpkgs.lib.mkDefault false;} # Disable niri cachix globally; enabled per-host in constellation.niri
      {
        nixpkgs.overlays = overlays;
      }
      # Load all modules from the modules directory
      (
        let
          getAllValues = set: let
            recurse = value:
              if builtins.isAttrs value
              then builtins.concatLists (map recurse (builtins.attrValues value))
              else [value];
          in
            recurse set;
          modules = inputs.haumea.lib.load {
            src = ../modules;
            loader = inputs.haumea.lib.loaders.path;
          };
        in
          getAllValues modules
      )
    ];

    homeManagerModulesFor = hmInput: [
      hmInput.nixosModules.home-manager
      {
        home-manager.sharedModules = [
          inputs.nix-index-database.homeModules.nix-index
        ];
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = false;
        home-manager.backupFileExtension = "bak";
        home-manager.users.arosenfeld = import ../home/home.nix;
      }
    ];
    homeManagerModules = homeManagerModulesFor inputs.home-manager;
    lightHosts = ["raspi3" "octopi" "r2s"];
  in {
    inherit
      loadPackages
      overlays
      baseModules
      homeManagerModulesFor
      homeManagerModules
      lightHosts
      ;

    mkLinuxSystem = {
      mods,
      enableHomeManager ? true,
      nixpkgsInput ? inputs.nixpkgs,
      homeManagerInput ? inputs.home-manager,
    }:
      nixpkgsInput.lib.nixosSystem {
        # Arguments to pass to all modules.
        specialArgs = {inherit self inputs;};
        modules =
          baseModules
          ++ (
            if enableHomeManager
            then homeManagerModulesFor homeManagerInput
            else []
          )
          ++ mods;
      };
  };
}
