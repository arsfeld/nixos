{
  config,
  pkgs,
  ...
}: {
  virtualisation.lxd = {
    enable = false;
    recommendedSysctlSettings = true;
  };

  age.secrets.cloudflare = {
    file = ../secrets/cloudflare.age;
    owner = "acme";
    group = "acme";
  };

  security.acme.acceptTerms = true;

  security.acme.defaults = {
    email = "arsfeld@gmail.com";
    dnsResolver = "1.1.1.1:53";
    dnsProvider = "cloudflare";
    credentialsFile = config.age.secrets.cloudflare.path;
  };

  virtualisation.docker = {
    enable = true;
    liveRestore = false;
    extraOptions = "--registry-mirror=https://mirror.gcr.io";
  };

  virtualisation.libvirtd.enable = true;
  security.polkit.enable = true;

  services.tailscale.enable = true;

  networking.firewall.trustedInterfaces = ["tailscale0"];

  virtualisation.oci-containers.backend = "docker";
  #virtualisation.podman.dockerCompat = true;
}
