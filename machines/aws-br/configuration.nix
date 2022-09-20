{modulesPath, ...}: {
  imports = [
    "${modulesPath}/virtualisation/amazon-image.nix"
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
  ];
  ec2.hvm = true;

  ec2.efi = true;

  nix.settings.experimental-features = ["nix-command" "flakes"];

  networking.hostName = "aws-br";

  # services.plex = {
  #   enable = true;
  # };
  # virtualisation.docker.enable = true;

  networking.firewall.allowedTCPPorts = [22 80 443 32400];

  # virtualisation.oci-containers.containers."plex" = {
  #   environment = {
  #     TZ = "America/SaoPaulo";
  #     VERSION = "latest";
  #   };
  #   extraOptions = ["--network=host"];
  #   image = "linuxserver/plex";
  #   volumes = [
  #     "/var/lib/plex:/config"
  #     "/mnt/media:/mnt/media"
  #   ];
  # };
  services.radarr = {
    enable = true;
  };
  services.sonarr = {
    enable = true;
  };
}
