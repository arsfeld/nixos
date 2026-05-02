{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11"; # Core nixpkgs - stable 25.11
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable"; # Unstable packages for latest versions
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*"; # Determinate Nix
    disko.url = "github:nix-community/disko"; # Declarative disk partitioning
    disko.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix"; # sops-nix secret management
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    home-manager-unstable.url = "github:nix-community/home-manager"; # Unstable HM for hosts on nixpkgs-unstable
    home-manager-unstable.inputs.nixpkgs.follows = "nixpkgs-unstable";
    deploy-rs.url = "github:serokell/deploy-rs"; # Remote deployment tool
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts"; # Flake framework for modular development
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    haumea.url = "github:nix-community/haumea"; # File tree loader for Nix
    haumea.inputs.nixpkgs.follows = "nixpkgs";
    git-hooks.url = "github:cachix/git-hooks.nix"; # Git hooks framework
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    nix-flatpak.url = "github:gmodena/nix-flatpak"; # Flatpak support for NixOS
    nix-index-database.url = "github:nix-community/nix-index-database"; # Faster command-not-found
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";
    harmonia.url = "github:nix-community/harmonia"; # Binary cache server
    harmonia.inputs.nixpkgs.follows = "nixpkgs";
    eh5.url = "github:EHfive/flakes"; # EH5's flake collection (fake-hwclock module)
    eh5.inputs.nixpkgs.follows = "nixpkgs";
    vpn-confinement.url = "github:Maroka-chan/VPN-Confinement"; # VPN namespace confinement for services
    niri.url = "github:sodiboo/niri-flake"; # Niri compositor with declarative Nix config
    det-nix-eval-jobs.url = "https://flakehub.com/f/DeterminateSystems/nix-eval-jobs/*"; # Determinate Nix eval-jobs
  };

  outputs = {self, ...} @ inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} (
      {...}: {
        imports = [
          ./flake-modules/lib.nix
          ./flake-modules/hosts.nix
          ./flake-modules/deploy.nix
          ./flake-modules/colmena.nix
          ./flake-modules/checks.nix
          ./flake-modules/images.nix
          ./flake-modules/dev.nix
        ];

        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ];
      }
    );
}
