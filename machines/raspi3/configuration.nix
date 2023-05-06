# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).
{
  config,
  pkgs,
  ...
}: {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ../../common/common.nix
    ../../common/users.nix
  ];

  # Use the extlinux boot loader. (NixOS wants to enable GRUB by default)
  boot.loader.grub.enable = false;

  boot.loader.raspberryPi = {
    enable = true;
    version = 3;
    uboot = {
      enable = true;
    };
  };

  networking.hostName = "raspi3";
  time.timeZone = "America/Toronto";

  services.tailscale.enable = true;

  services.adguardhome = {
    enable = true;
  };

  virtualisation.podman.dockerSocket.enable = true;

  virtualisation.oci-containers = {
    backend = "podman";
    containers = {
      homeassistant = {
        volumes = ["/etc/home-assistant:/config"];
        environment.TZ = "America/Toronto";
        image = "ghcr.io/home-assistant/home-assistant:stable";
        extraOptions = [
          "--network=host"
          "--privileged"
          "--label"
          "io.containers.autoupdate=image"
        ];
      };
    };
  };

  services.home-assistant = {
    enable = false;
    config = {
      # homeassistant = {
      #   name = "Home";
      #   latitude = "!secret latitude";
      #   longitude = "!secret longitude";
      #   elevation = "!secret elevation";
      #   unit_system = "metric";
      #   time_zone = "America/Toronto";
      # };
      #frontend = {
      #  themes = "!include_dir_merge_named themes";
      #};
      # http = {
      #   server_host = "::1";
      #   trusted_proxies = ["::1"];
      #   #use_x_forwarded_for = true;
      # };
      #http = {};
      #feedreader.urls = ["https://nixos.org/blogs.xml"];
      #lovelace.mode = "storage";
    };
  };

  services.openssh.enable = true;
  networking.firewall.enable = false;

  system.stateVersion = "23.05";
}
