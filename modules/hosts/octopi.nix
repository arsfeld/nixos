# octopi: OctoPrint on a Raspberry Pi. Configuration in ./octopi/.
{config, ...}: let
  features = config.flake.modules.nixos;
in {
  configurations.nixos.octopi = {
    homeManager = false;
    module.imports = [
      features.netdata-client
      features.tsnsrv
      features.virtualization
    ];
  };
}
