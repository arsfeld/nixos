{
  config,
  lib,
  self,
  inputs,
  ...
}: let
  hosts = config.configurations.nixos;
in {
  options.configurations.nixos = lib.mkOption {
    description = "NixOS hosts. Each becomes nixosConfigurations.<name>.";
    default = {};
    type = lib.types.lazyAttrsOf (lib.types.submodule {
      options = {
        module = lib.mkOption {
          type = lib.types.deferredModule;
          description = "The host's NixOS configuration.";
        };
        nixpkgs = lib.mkOption {
          type = lib.types.enum ["stable" "unstable"];
          default = "stable";
          description = "The nixpkgs (and matching home-manager) the host is built from.";
        };
        homeManager = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether the host gets home-manager and home/home.nix.";
        };
        tier = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Deployment tier, selected by `just deploy @<tier>`.";
        };
        ci = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether CI builds the host (membership of ciMatrix).";
        };
      };
    });
  };

  config = {
    flake = {
      hosts = builtins.attrNames hosts;

      # Exposed as the `tiers` flake output; the justfile's @tier selectors
      # and the README table read it.
      tiers =
        lib.foldlAttrs (acc: name: h:
          if h.tier == null
          then acc
          else acc // {${h.tier} = (acc.${h.tier} or []) ++ [name];})
        {}
        hosts;

      unstableHosts = builtins.attrNames (lib.filterAttrs (_: h: h.nixpkgs == "unstable") hosts);
      lightHosts = builtins.attrNames (lib.filterAttrs (_: h: !h.homeManager) hosts);
      ciExcludedHosts = builtins.attrNames (lib.filterAttrs (_: h: !h.ci) hosts);

      # CI build matrix, with auto-detected platforms. Consumed by
      # .github/workflows/build.yml via `nix eval`. aarch64 hosts build on
      # GitHub's free native ARM runners (public repo) instead of slow QEMU
      # emulation, which used to time out at 2h.
      ciMatrix =
        map (hostName: let
          platform = self.nixosConfigurations.${hostName}.config.nixpkgs.hostPlatform.system;
        in {
          host = hostName;
          inherit platform;
          runner =
            if platform == "aarch64-linux"
            then "ubuntu-24.04-arm"
            else "ubuntu-latest";
        })
        (builtins.filter (name: hosts.${name}.ci) (builtins.attrNames hosts));

      nixosConfigurations = lib.mapAttrs (name: h: let
        unstable = h.nixpkgs == "unstable";
      in
        self.lib.mkLinuxSystem {
          enableHomeManager = h.homeManager;
          nixpkgsInput =
            if unstable
            then inputs.nixpkgs-unstable
            else inputs.nixpkgs;
          homeManagerInput =
            if unstable
            then inputs.home-manager-unstable
            else inputs.home-manager;
          mods = [h.module];
        })
      hosts;
    };
  };
}
