{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
  ];

  # Orange Pi Zero 3 hardware configuration
  # SoC: Allwinner H618 (ARM Cortex-A53 quad-core)
  # Device tree is available in mainline kernel 6.6+
  hardware.deviceTree.name = "allwinner/sun50i-h618-orangepi-zero3.dtb";

  boot = {
    loader = {
      timeout = 3;
      grub.enable = false;
      generic-extlinux-compatible = {
        enable = true;
        configurationLimit = 3;
      };
    };

    # Include USB serial drivers for CH340 (3D printer connection)
    kernelModules = ["ch341" "cdc_acm"];

    initrd.availableKernelModules = ["usbhid"];
    initrd.kernelModules = [];
    extraModulePackages = [];

    # Optimize for low memory (1GB RAM)
    kernel.sysctl = {
      "vm.vfs_cache_pressure" = 50;
      "vm.dirty_ratio" = 20;
      "vm.swappiness" = 60;
    };
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = ["noatime"];
    };
  };

  # Enable swap for 1GB RAM system
  swapDevices = [
    {
      device = "/swapfile";
      size = 2048; # 2GB swap
    }
  ];

  # Network configuration
  networking.useDHCP = lib.mkDefault true;
  networking.interfaces.eth0.useDHCP = lib.mkDefault true;
  networking.interfaces.wlan0.useDHCP = lib.mkDefault true;

  # Platform configuration
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  powerManagement.cpuFreqGovernor = lib.mkDefault "ondemand";

  # USB serial device permissions for OctoPrint
  services.udev.extraRules = ''
    # CH340 serial converter for 3D printer
    SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666", GROUP="dialout", SYMLINK+="ttyPrinter"
  '';
}
