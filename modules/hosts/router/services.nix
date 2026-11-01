{
  configurations.nixos.router.module = {
    config,
    lib,
    pkgs,
    ...
  }: {
    imports = [
      ../../../packages/network-metrics-exporter/module.nix
    ];
  };
}
