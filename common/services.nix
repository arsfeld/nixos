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
      # Used for UEFI boot of Home Assistant OS guest image
      # qemu.ovmf.enable = true;
    };
  };

  services.zerotierone = {
    enable = true;
    joinNetworks = ["35c192ce9b7b5113"];
  };

  services.tailscale.enable = false;
}
