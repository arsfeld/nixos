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

  virtualisation = {
    libvirtd = {
      enable = false;
      # qemu.ovmf.enable = true;
    };
  };

  # services.zerotierone = {
  #   enable = true;
  #   joinNetworks = ["35c192ce9b7b5113"];
  # };

  networking.firewall.trustedInterfaces = ["tailscale0"];

  services.tailscale.enable = true;
}
