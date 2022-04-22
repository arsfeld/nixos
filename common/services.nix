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

  services.zerotierone = {
    enable = true;
    joinNetworks = ["35c192ce9b7b5113"];
  };

  services.tailscale.enable = false;
}
