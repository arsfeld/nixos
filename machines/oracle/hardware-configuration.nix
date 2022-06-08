{modulesPath, ...}: {
  imports = [(modulesPath + "/profiles/qemu-guest.nix")];
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  fileSystems."/boot" = { device = "/dev/disk/by-uuid/63D2-AF76"; fsType = "vfat"; };
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = { device = "/dev/mapper/ocivolume-root"; fsType = "xfs"; };
}
