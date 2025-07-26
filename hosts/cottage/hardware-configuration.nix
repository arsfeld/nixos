# Hardware configuration for cottage - nixos-infect version
# This imports the existing ZFS boot-pool instead of creating new filesystems
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ehci_pci" "ahci" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ "zfs" ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Support ZFS
  boot.supportedFilesystems = [ "zfs" ];
  
  # Import existing ZFS pools
  boot.zfs.extraPools = [ "boot-pool" ];
  
  # Don't force import - the pool should be clean
  boot.zfs.forceImportRoot = false;
  boot.zfs.forceImportAll = false;

  # Root filesystem from boot-pool
  fileSystems."/" = {
    device = "boot-pool/ROOT/nixos";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  # EFI boot partition
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/6F43-89F4";
    fsType = "vfat";
  };

  # Swap (if needed)
  swapDevices = [ ];

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