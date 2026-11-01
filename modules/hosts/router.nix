# router: the home router. Configuration in ./router/.
{
  config,
  inputs,
  ...
}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.router.module.imports = [
    inputs.disko.nixosModules.disko
    features.podman
  ];
}
