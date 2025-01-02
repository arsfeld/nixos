{
  lib,
  pkgs,
  ...
}: {
  virtualisation.docker = {
    enable = lib.mkDefault true;
    extraOptions = "--registry-mirror=https://mirror.gcr.io";
    autoPrune.enable = true;
    daemon.settings = {
      live-restore = true;
    };
  };

  virtualisation.libvirtd.enable = true;

  environment.systemPackages = with pkgs; [
    virt-manager
  ];

  virtualisation.oci-containers.backend = lib.mkDefault "docker";
}
