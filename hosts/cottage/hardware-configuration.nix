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
  # nofail ensures boot continues even if mount fails
  # Retry service below will attempt to mount later if initial mount fails
  fileSystems."/mnt/storage" = {
    device = "UUID=61994cd0-27c3-4f00-a021-0c16840df463";
    fsType = "bcachefs";
    options = ["noatime" "nofail"];
  };

  # Retry mounting storage if it failed at boot (e.g., devices not ready yet)
  systemd.services.bcachefs-storage-retry = {
    description = "Retry bcachefs storage mount";
    wantedBy = ["multi-user.target"];
    after = ["local-fs.target"];
    path = [pkgs.util-linux];
    script = ''
      if ! mountpoint -q /mnt/storage; then
        mount /mnt/storage
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  # Timer to retry mount periodically if still not mounted
  systemd.timers.bcachefs-storage-retry = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "60s";
      Unit = "bcachefs-storage-retry.service";
    };
  };

  # CPU microcode updates
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Enable firmware
  hardware.enableRedistributableFirmware = lib.mkDefault true;

  # Network interfaces
  networking.interfaces.eno1.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
