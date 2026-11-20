{
  config,
  inputs,
  ...
}: {
  flake.lib = let
    # packages/<name>/package.nix, the nixpkgs by-name layout. Other files in a
    # package directory (module.nix, sources) are ignored by the loader.
    # The lib comes from the flake input, not pkgs: the overlay calls this with
    # `final`, and reading final.lib while building the overlay recurses forever.
    loadPackages = pkgs:
      inputs.nixpkgs.lib.packagesFromDirectoryRecursive {
        inherit (pkgs) callPackage;
        directory = ../../packages;
      };

    # Common overlays used everywhere
    overlays = [
      (import ../../overlays/cve-2026-111497.nix)
      (import ../../overlays/python-packages.nix)
      (import ../../overlays/glances.nix)
      (import ../../overlays/topgrade-aws-lc.nix)
      (import ../../overlays/vscode-ripgrep-universal.nix)
      # nixpkgs-unstable as `pkgs.unstable`, one instance per package set.
      # It inherits the host's nixpkgs config (allowUnfree, …) and no overlays:
      # what we take from it is plain upstream packages, and our overlays
      # target stable. Never `import inputs.nixpkgs*` inside a module instead.
      (final: prev: {
        unstable = import inputs.nixpkgs-unstable {
          inherit (final.stdenv.hostPlatform) system;
          inherit (final) config;
        };
      })
      # Load packages from ./packages
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
      # Features every host has; see modules/base/.
      config.flake.modules.nixos.base
    ];

    # The home-manager wiring shared by NixOS hosts and the Macs; takes the
    # module for the system class (hmInput.nixosModules or .darwinModules).
    homeManagerModulesFor = hmModule: [
      hmModule
      {
        home-manager.sharedModules = [
          inputs.nix-index-database.homeModules.nix-index
        ];
        home-manager.extraSpecialArgs = {inherit inputs;};
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = false;
        home-manager.backupFileExtension = "bak";
        home-manager.users.arosenfeld = import ../../home/home.nix;
      }
    ];
    homeManagerModules = homeManagerModulesFor inputs.home-manager.nixosModules.home-manager;

    # What the Macs add to home/home.nix, shared by the standalone
    # homeConfigurations.arosenfeld and the darwinConfigurations.
    # The Macs run Determinate Nix, whose /etc/nix/nix.conf sets eval-cores and
    # lazy-trees. Activation puts nix.package on PATH, and upstream pkgs.nix
    # warns on every call about those settings.
    macHomeModule = {pkgs, ...}: {
      nix.package = inputs.determinate.inputs.nix.packages.${pkgs.stdenv.hostPlatform.system}.nix;
    };
    macNixpkgsConfig = {
      allowUnfree = true;
      android_sdk.accept_license = true;
    };
  in {
    inherit
      loadPackages
      overlays
      baseModules
      homeManagerModulesFor
      homeManagerModules
      macHomeModule
      macNixpkgsConfig
      ;

    mkLinuxSystem = {
      mods,
      enableHomeManager ? true,
      nixpkgsInput ? inputs.nixpkgs,
      homeManagerInput ? inputs.home-manager,
    }:
      nixpkgsInput.lib.nixosSystem {
        modules =
          baseModules
          ++ (
            if enableHomeManager
            then homeManagerModulesFor homeManagerInput.nixosModules.home-manager
            else []
          )
          ++ mods;
      };
  };
}
