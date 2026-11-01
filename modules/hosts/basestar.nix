# basestar: public-facing server on Oracle Cloud, *.arsfeld.dev and the k3s
# cluster. Configuration in ./basestar/.
{config, ...}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.basestar = {
    tier = "tier1";
    module.imports = [
      features.backrest
      features.media
      features.netdata-client
      features.podman
      features.tsnsrv
      features.virtualization
    ];
  };
}
