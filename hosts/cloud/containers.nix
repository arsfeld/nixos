{
  config,
  self,
  ...
}: let
  ports = config.media.gateway.ports;
in {
  virtualisation.oci-containers.containers = {
    whoogle = {
      image = "benbusby/whoogle-search:latest";
      ports = ["${toString ports.whoogle}:5000"];
    };

    metube = {
      image = "ghcr.io/alexta69/metube";
      volumes = ["/var/lib/metube:/downloads"];
      ports = ["${toString ports.metube}:8081"];
    };
  };
}
