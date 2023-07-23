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
  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "nvme"];
  disko.devices = import ./disk-config.nix {
    lib = pkgs.lib;
  };
  boot.loader.systemd-boot.enable = true;
  services.openssh.enable = true;

  nixpkgs.overlays = [
    (final: prev: {
      miniupnpd-nftables = super.callPackage ./pkgs/upnp-nftables {firewall = "nftables";};
    })
  ];

  system.stateVersion = "23.05";
}
