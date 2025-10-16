{
  config,
  pkgs,
  self,
  inputs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
  ];

  nixpkgs.hostPlatform = "aarch64-linux";

  networking.hostName = "octopi";
  time.timeZone = "America/Toronto";

  # Tailscale configuration
  services.tailscale.enable = true;

  age.secrets.tailscale-key.file = "${self}/secrets/tailscale-key.age";

  # Expose OctoPrint via Tailscale Funnel
  services.tsnsrv = {
    enable = true;
    defaults = {
      tags = ["tag:service"];
      authKeyPath = config.age.secrets.tailscale-key.path;
      ephemeral = true;
    };
    services = {
      octoprint = {
        toURL = "http://127.0.0.1:5000";
        funnel = true;
      };
    };
  };

  # OctoPrint configuration
  services.octoprint = {
    enable = true;
    plugins = plugins:
      with plugins; [
        themeify
        stlviewer
      ];
  };

  # TODO: Raspotify configuration
  # Raspotify is not currently available as a NixOS service
  # Consider using librespot package manually or creating a custom service
  # services.raspotify = {
  #   enable = true;
  #   settings = {
  #     device_name = "OctoPi Speaker";
  #     bitrate = 320;
  #     device_type = "speaker";
  #   };
  # };

  # Ensure dialout group exists for serial access
  users.groups.dialout = {};

  # Add octoprint user to dialout group for serial port access
  users.users.octoprint.extraGroups = ["dialout"];

  # SSH access
  services.openssh.enable = true;

  # Disable firewall for simplicity (protected by Tailscale)
  networking.firewall.enable = false;

  system.stateVersion = "25.05";
}
