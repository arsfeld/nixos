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

  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "nvme" "uas" "sd_mod"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-intel"];
  boot.extraModulePackages = [];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/e354e7b9-0b91-4d17-a3f1-4946222266e3";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/C649-8B93";
    fsType = "vfat";
  };

  fileSystems."/mnt/data" = {
    device = "data";
    fsType = "zfs";
    options = ["nofail"];
  };

  fileSystems."/home" = {
    device = "data/homes";
    fsType = "zfs";
    options = ["nofail"];
  };

  swapDevices = [
    {device = "/dev/disk/by-uuid/ecced37a-a038-493b-96e6-936ac9dbdc57";}
  ];

  zramSwap.enable = lib.mkForce false;

  # The global useDHCP flag is deprecated, therefore explicitly set to false here.
  # Per-interface useDHCP will be mandatory in the future, so this generated config
  # replicates the default behaviour.
  networking.useDHCP = lib.mkDefault false;
  networking.interfaces.eno1.useDHCP = true;

  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}