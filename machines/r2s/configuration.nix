# save as sd-image.nix somewhere
{modulesPath, ...}: {
  imports = [
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
    ./hardware.nix
    (import ./networking.nix {
      internalInterface = "eth1"; # or w/e ethernet interface you want to connect your raspberry pi to
      externalInterface = "eth0"; # or w/e interface you get your internet connection to your pc
    })
  ];

  services.openssh = {
    enable = true;
    permitRootLogin = "yes";
  };

  networking.hostName = "r2s";
  networking.firewall.enable = false;

  services.adguardhome = {
    enable = true;
  };

  virtualisation.oci-containers = {
    containers.homeassistant = {
      volumes = ["home-assistant:/config"];
      environment.TZ = "Europe/Berlin";
      image = "ghcr.io/home-assistant/home-assistant:stable"; # Warning: if the tag does not change, the image will not be updated
      extraOptions = [
        "--network=host"
      ];
    };
  };

  # put your own configuration here, for example ssh keys:
  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
  ];
}
