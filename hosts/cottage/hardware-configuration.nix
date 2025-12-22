# Hardware configuration for cottage
# Filesystems managed by disko-config.nix
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = ["xhci_pci" "ehci_pci" "ahci" "usb_storage" "sd_mod"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-intel"];
  boot.extraModulePackages = [];

  # Boot filesystems managed by disko-config.nix

  # bcachefs storage array (4x 4TB, replicas=2, ~7TB usable)
  fileSystems."/mnt/storage" = {
    device = "UUID=61994cd0-27c3-4f00-a021-0c16840df463";
    fsType = "bcachefs";
    options = ["noatime" "nofail"];
  };

  # CPU microcode updates
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Enable firmware
  hardware.enableRedistributableFirmware = lib.mkDefault true;

  # Network interfaces
  networking.interfaces.eno1.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
