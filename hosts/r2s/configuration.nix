# save as sd-image.nix somewhere
{modulesPath, ...}: {
  imports = [
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
    ./hardware.nix
    (import ./networking.nix {
      internalInterface = "enu1"; # or w/e ethernet interface you want to connect your raspberry pi to
      externalInterface = "end0"; # or w/e interface you get your internet connection to your pc
    })
  ];

  services.openssh = {
    enable = true;
    permitRootLogin = "yes";
  };

  networking.hostName = "r2s";
  networking.firewall.enable = false;

  virtualisation.oci-containers.containers = {
    watchtower = {
      image = "containrrr/watchtower";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
      ];
    };

    homeassistant = {
      volumes = ["/var/lib/home-assistant:/config"];
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

  # put your own configuration here, for example ssh keys:
  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
  ];
}
