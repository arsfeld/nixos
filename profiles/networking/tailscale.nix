{
  config,
  lib,
  ...
}: {
  services.tailscale.enable = true;

  networking.firewall = {
    checkReversePath = "loose";
    trustedInterfaces = ["tailscale0"];
  };
}
