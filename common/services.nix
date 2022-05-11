{
  config,
  pkgs,
  ...
}: {
  virtualisation.lxd.enable = true;

  virtualisation.docker = {
    enable = true;
    liveRestore = false;
    extraOptions = "--registry-mirror=https://mirror.gcr.io";
  };

  services.tailscale.enable = true;

  networking.firewall.trustedInterfaces = ["tailscale0"];
}
