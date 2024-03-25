{
  config,
  pkgs,
  ...
}: {
  virtualisation.lxd = {
    enable = false;
    recommendedSysctlSettings = true;
  };

  virtualisation.docker = {
    enable = true;
    liveRestore = false;
    extraOptions = "--registry-mirror=https://mirror.gcr.io";
    autoPrune.enable = true;
  };

  virtualisation.libvirtd.enable = true;
  security.polkit.enable = true;

  services.tailscale.enable = true;

  networking.firewall.trustedInterfaces = ["tailscale0"];

  virtualisation.oci-containers.backend = "docker";
  #virtualisation.podman.dockerCompat = true;
}
