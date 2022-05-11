{
  config,
  pkgs,
  ...
}: {
  imports = [
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
    ./hardware-configuration.nix
  ];

  boot.supportedFilesystems = ["zfs"];

  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.device = "/dev/xvda"; #nodev" for efi only

  networking.useDHCP = false;
  networking.interfaces.eth0.useDHCP = false;
  networking.hostId = "ba2059f3";

  networking.interfaces.eth0 = {
    ipv4.addresses = [
      {
        address = "209.209.8.178";
        prefixLength = 24;
      }
    ];
  };

  services.xe-guest-utilities.enable = true;

  networking.defaultGateway = "209.209.8.1";
  networking.nameservers = ["8.8.8.8"];
  networking.hostName = "virgon";

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [22 6443];

  services.k3s.enable = true;
  services.k3s.role = "server";
  services.k3s.extraFlags = toString [
    # "--kubelet-arg=v=4" # Optionally add additional args to k3s
  ];
  environment.systemPackages = [pkgs.k3s];

  # services.sabnzbd = {
  #   enable = true;
  #   user = "media";
  #   group = "media";
  # };

  # services.nzbhydra2 = {
  #   enable = true;
  # };

  # services.caddy = {
  #   enable = true;
  #   config = ''
  #     209.209.8.178, virgon.arsfeld.net {
  #       root * /mnt/data
  #       file_server browse
  #     }
  #   '';
  # };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.05"; # Did you read the comment?
}
