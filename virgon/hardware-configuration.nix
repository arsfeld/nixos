# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ ];

  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "sr_mod" "xen_blkfront" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/9c62a499-39dc-4db0-b4f5-789e476c8399";
      fsType = "xfs";
    };

  fileSystems."/mnt/data" = { device = "data"; fsType = "zfs"; };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/68fa148d-f20c-4045-aa4d-0b177c9971b6"; }
    ];

}
