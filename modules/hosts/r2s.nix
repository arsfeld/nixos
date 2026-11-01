# r2s: NanoPi R2S router board. Configuration in ./r2s/.
{config, ...}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.r2s = {
    homeManager = false;
    module.imports = [
      features.netdata-client
      features.virtualization
    ];
  };
}
