# raider: desktop workstation and the deploy driver. Configuration in ./raider/.
{
  config,
  inputs,
  ...
}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.raider = {
    nixpkgs = "unstable";
    tier = "tier1";
    module.imports = [
      inputs.disko.nixosModules.disko
      features.backrest
      features.desktop
      features.development
      features.gaming
      features.media
      features.netdata-client
      features.tsnsrv
      features.virtualization
    ];
  };
}
