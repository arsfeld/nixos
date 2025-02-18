{
  self,
  pkgs,
  config,
  lib,
  ...
}: {
  imports = [
    ./disko-config.nix
    ./hardware-configuration.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  virtualisation.oci-containers.backend = "podman";
  virtualisation.docker.enable = false;

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
  };

  virtualisation.incus = {
    enable = true;
    ui.enable = true;
  };
  networking.nftables.enable = true;

  boot = {
    binfmt.emulatedSystems = ["aarch64-linux"];
    kernelModules = ["kvm-intel"];
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "hpe";

  # networking.interfaces.eno1.ipv4.addresses = [
  #   {
  #     address = "192.168.1.182";
  #     prefixLength = 24;
  #   }
  # ];

  networking.bridges = {
    "br0" = {
      interfaces = ["eno1"];
    };
  };
  networking.useDHCP = false;
  networking.interfaces.br0.useDHCP = true;

  #networking.defaultGateway = "192.168.1.1";
  #networking.nameservers = ["8.8.8.8"];

  services.tailscale.enable = true;

  services.openssh.enable = true;
}
