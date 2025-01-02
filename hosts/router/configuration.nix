args @ {
  modulesPath,
  lib,
  pkgs,
  ...
}:
with lib; {
  imports = [
    ../../common/users.nix
    (modulesPath + "/installer/scan/not-detected.nix")
    # https://github.com/NixOS/nixpkgs/pull/239028
    ./miniupnpd-nftables.nix
    ./network.nix
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];

  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "nvme"];
  disko.devices = import ./disk-config.nix {
    lib = pkgs.lib;
  };
  boot.loader.systemd-boot.enable = true;
  services.openssh.enable = true;
  services.cockpit.enable = true;
  services.ntopng.enable = true;
  services.ntopng.httpPort = 3333;
  services.fail2ban.enable = true;
  services.fail2ban.ignoreIP = ["192.168.0.0/16"];

  virtualisation.podman.enable = true;
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

  systemd.timers.podman-auto-update = {
    description = "Podman auto-update timer";
    partOf = ["podman-auto-update.service"];
    wantedBy = ["timers.target"];
    timerConfig.OnCalendar = "weekly";
  };

  nixpkgs.overlays = [
    (self: super: {
      miniupnpd-nftables = super.callPackage ./pkgs/miniupnpd.nix {firewall = "nftables";};
    })
  ];

  system.stateVersion = "23.05";
}
