{
  config,
  pkgs,
  self,
  inputs,
  ...
}: {
  imports =
    self.nixosSuites.base
    ++ [
      ./hardware-configuration.nix
    ];

  nixpkgs.hostPlatform = "aarch64-linux";

  services.netdata.enable = true;

  networking.hostName = "raspi3";
  time.timeZone = "America/Toronto";

  services.tailscale.enable = true;

  services.octoprint.enable = true;

  #virtualisation.podman.dockerSocket.enable = true;

  # virtualisation.oci-containers = {
  #   backend = "podman";
  #   containers = {
  #     homeassistant = {
  #       volumes = ["/etc/home-assistant:/config"];
  #       environment.TZ = "America/Toronto";
  #       image = "ghcr.io/home-assistant/home-assistant:stable";
  #       extraOptions = [
  #         "--network=host"
  #         "--privileged"
  #         "--label"
  #         "io.containers.autoupdate=image"
  #       ];
  #     };
  #   };
  # };

  # systemd.timers.podman-auto-update = {
  #   description = "Podman auto-update timer";
  #   partOf = ["podman-auto-update.service"];
  #   wantedBy = ["timers.target"];
  #   timerConfig.OnCalendar = "weekly";
  # };

  services.openssh.enable = true;
  networking.firewall.enable = false;

  system.stateVersion = "23.05";
}
