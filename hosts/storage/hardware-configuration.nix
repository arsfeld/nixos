# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
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

  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "mpt3sas" "nvme" "usbhid" "uas" "sd_mod" "ip6table_filter"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-intel" "it87"];
  boot.extraModulePackages = with config.boot.kernelPackages; [it87];
  boot.kernelParams = ["acpi_osi=\"Windows 2015\""];

  environment.systemPackages = with pkgs; [
    mergerfs
    bcachefs-tools
  ];

  fileSystems."/mnt/data" = {
    fsType = "bcachefs";
    device = "/dev/disk/by-uuid/0f89df18-94d3-4083-8b21-2e5ebac00a44";
    options = ["compression=zstd" "nofail"];
  };

  fileSystems."/mnt/storage" = {
    fsType = "bcachefs";
    device = "/dev/disk/by-uuid/74d26e9d-3e6c-4b33-9f63-d91bf13606b0";
    options = ["compression=zstd" "nofail"];
  };

  systemd.services.mount-storage = {
    description = "mount storage";
    script = "/run/current-system/sw/bin/mount /mnt/storage || true";
    wantedBy = ["multi-user.target"];
  };

  systemd.services.docker.after = ["mount-storage.service"];

  networking.useDHCP = lib.mkDefault true;

  powerManagement.powertop.enable = true;

  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
