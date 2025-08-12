# Hardware configuration for raider gaming system
# Generated based on actual hardware scan
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

  # Boot configuration
  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "nvme" "usb_storage" "sd_mod"];
  boot.initrd.kernelModules = ["amdgpu"]; # AMD GPU early KMS
  boot.kernelModules = ["kvm-intel"];
  boot.extraModulePackages = [];

  # Filesystems will be managed by disko
  # The disko-config.nix handles all filesystem configuration

  # Network interfaces
  networking.useDHCP = lib.mkDefault true;
  # Uncomment specific interfaces if needed:
  # networking.interfaces.enp6s0.useDHCP = lib.mkDefault true;
  # networking.interfaces.enp7s0.useDHCP = lib.mkDefault true;
  # networking.interfaces.wlp5s0.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Intel CPU microcode updates
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Enable firmware
  hardware.enableRedistributableFirmware = true;
  hardware.enableAllFirmware = true;

  # AMD GPU configuration for Radeon RX 6650 XT
  services.xserver.videoDrivers = ["amdgpu"];

  # AMD GPU hardware acceleration
  hardware.graphics = {
    enable = true;
    enable32Bit = true;

    extraPackages = with pkgs; [
      amdvlk
      rocmPackages.clr.icd
      mesa
    ];

    extraPackages32 = with pkgs; [
      driversi686Linux.amdvlk
    ];
  };

  # Enable AMD GPU OpenCL support
  hardware.amdgpu.opencl.enable = true;

  # High DPI console for modern displays
  console.font = lib.mkDefault "${pkgs.terminus_font}/share/consolefonts/ter-u28n.psf.gz";
}
