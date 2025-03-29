{
  config,
  self,
  ...
}: let
  services = config.media.gateway.services;
in {
  virtualisation.oci-containers.containers = {
    whoogle = {
      image = "benbusby/whoogle-search:latest";
      ports = ["${toString services.whoogle.port}:5000"];
    };

    metube = {
      image = "ghcr.io/alexta69/metube";
      volumes = ["/var/lib/metube:/downloads"];
      ports = ["${toString services.metube.port}:8081"];
    };
  };
}
