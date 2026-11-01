# blackbird: ASUS ROG Zephyrus G14 laptop. Configuration in ./blackbird/.
{
  config,
  inputs,
  ...
}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.blackbird.module.imports = [
    inputs.disko.nixosModules.disko
    features.desktop
    features.development
    features.gaming
    features.netdata-client
    features.virtualization
  ];
}
