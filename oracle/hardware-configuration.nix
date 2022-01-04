{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  boot.loader = {
  efi = {
    canTouchEfiVariables = true;
    efiSysMountPoint = "/boot/efi"; # ← use the same mount point here.
  };
  grub = {
    efiSupport = true;
    # efiInstallAsRemovable = true;
    device = "nodev";
  };
  };
  fileSystems."/boot/efi" = { device = "/dev/disk/by-uuid/7275-636E"; fsType = "vfat"; };
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = { device = "/dev/mapper/ocivolume-root"; fsType = "xfs"; };
  boot.supportedFilesystems = [ "zfs" ];
}
