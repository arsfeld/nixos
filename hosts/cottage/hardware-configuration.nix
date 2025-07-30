# Hardware configuration for cottage - nixos-infect version
# This imports the existing ZFS boot-pool instead of creating new filesystems
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
  boot.initrd.kernelModules = ["zfs"];
  boot.kernelModules = ["kvm-intel"];
  boot.extraModulePackages = [];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/02b6a197-04da-48a8-904a-96f9f4d810e6";
    fsType = "ext4";
  };

  swapDevices = [
    {device = "/dev/disk/by-uuid/323526ac-f79e-4557-af6a-82962bcb7dbb";}
  ];

  # Support ZFS
  boot.supportedFilesystems = ["zfs"];

  # Don't force import - the pool should be clean
  boot.zfs.forceImportRoot = false;
  boot.zfs.forceImportAll = false;

  # CPU microcode updates
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Enable firmware
  hardware.enableRedistributableFirmware = lib.mkDefault true;

  # Network interfaces
  networking.interfaces.eno1.useDHCP = lib.mkDefault true;
  networking.interfaces.eth0.useDHCP = lib.mkDefault true;

  # Enable Intel graphics support (Haswell generation)
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vaapiIntel
      vaapiVdpau
      libvdpau-va-gl
    ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
