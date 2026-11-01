# raspi3: Raspberry Pi 3. Configuration in ./raspi3/.
{config, ...}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.raspi3 = {
    homeManager = false;
    module.imports = [
      features.netdata-client
      features.tsnsrv
      features.virtualization
    ];
  };
}
