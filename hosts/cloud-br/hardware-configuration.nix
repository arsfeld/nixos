{modulesPath, ...}: {
  imports = [(modulesPath + "/profiles/qemu-guest.nix")];
  boot.loader.efi = {
    canTouchEfiVariables = true;
    efiSysMountPoint = "/boot/efi"; # \E2\86\90 use the same mount point here.
  };
  boot.loader.grub = {
    efiSupport = true;
    #efiInstallAsRemovable = true;
    device = "nodev";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/f4f72f40-79e3-4def-8ec6-5aa39b870c1b";
    fsType = "xfs";
  };
  fileSystems."/boot/efi" = {
    device = "/dev/disk/by-uuid/8A98-E467";
    fsType = "vfat";
  };
  boot.initrd.availableKernelModules = ["ata_piix" "uhci_hcd" "xen_blkfront"];
  boot.initrd.kernelModules = ["nvme"];
  fileSystems."/" = {
    device = "/dev/mapper/ocivolume-root";
    fsType = "xfs";
  };
}
