{
  config,
  pkgs,
  ...
}: {
  virtualisation.docker = {
    enable = true;
    liveRestore = false;
    extraOptions = "--registry-mirror=https://mirror.gcr.io";
    autoPrune.enable = true;
  };

  virtualisation.libvirtd.enable = true;

  virtualisation.oci-containers.backend = "docker";
}
