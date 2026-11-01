# pegasus: secondary server. Configuration in ./pegasus/.
{
  config,
  inputs,
  ...
}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.pegasus.module.imports = [
    inputs.disko.nixosModules.disko
    features.backrest
    features.media
    features.netdata-client
    features.podman
    features.tsnsrv
    features.virtualization
  ];
}
