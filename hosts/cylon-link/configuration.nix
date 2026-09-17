# cylon-link: a Valve Steam Link running NixOS as an always-on helper.
# It boots through Valve's firmware and kexec; see ./boot and CLAUDE.md.
{config, ...}: {
  imports = [
    ./hardware.nix
    ./boot
  ];

  networking.hostName = "cylon-link";

  constellation.common.minimal = true;
  constellation.sops.enable = true;
  # Too heavy for 500 MB of RAM and a cross build.
  constellation.virtualization.enable = false;
  constellation.netdataClient.enable = false;
  # Determinate publishes no armv7l build, so use nixpkgs' Nix.
  determinate.enable = false;

  sops.secrets.tailscale-key.sopsFile = config.constellation.sops.commonSopsFile;
  services.tailscale.authKeyFile = config.sops.secrets.tailscale-key.path;

  # The device never compiles. A path missing from cache.arsfeld.dev should
  # fail the deploy, not start a build on one Cortex-A9 core.
  nix.settings.max-jobs = 0;

  system.stateVersion = "26.05";
}
