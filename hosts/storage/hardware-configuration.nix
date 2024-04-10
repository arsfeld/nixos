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
  boot.extraModulePackages = with config.boot.zfs.package.latestCompatibleLinuxPackages; [it87];

  fileSystems."/" = {
    device = "nix-pool/nixos/root";
    fsType = "zfs";
    options = ["zfsutil" "X-mount.mkdir"];
  };

  fileSystems."/home" = {
    device = "nix-pool/nixos/home";
    fsType = "zfs";
    options = ["zfsutil" "X-mount.mkdir"];
  };

  fileSystems."/var/lib" = {
    device = "nix-pool/nixos/var/lib";
    fsType = "zfs";
    options = ["zfsutil" "X-mount.mkdir"];
  };

  fileSystems."/var/lib/docker" = {
    device = "nix-pool/nixos/var/lib/docker";
    fsType = "zfs";
    options = ["zfsutil" "X-mount.mkdir"];
  };

  fileSystems."/var/log" = {
    device = "nix-pool/nixos/var/log";
    fsType = "zfs";
    options = ["zfsutil" "X-mount.mkdir"];
  };

  fileSystems."/boot" = {
    device = "bpool/nixos/root";
    fsType = "zfs";
    options = ["zfsutil" "X-mount.mkdir"];
  };

  fileSystems."/boot/efi" = {
    device = "/dev/disk/by-uuid/6EA2-2234";
    fsType = "vfat";
  };

  fileSystems."/mnt/data" = {
    device = "data";
    fsType = "zfs";
    options = ["zfsutil" "X-mount.mkdir"];
  };

  fileSystems."/mnt/data/media" = {
    device = "data/media";
    fsType = "zfs";
    options = ["zfsutil" "X-mount.mkdir"];
  };

  fileSystems."/mnt/data/files" = {
    device = "data/files";
    fsType = "zfs";
    options = ["zfsutil" "X-mount.mkdir"];
  };

  fileSystems."/mnt/data/backups" = {
    device = "data/backups";
    fsType = "zfs";
    options = ["zfsutil" "X-mount.mkdir"];
  };

  fileSystems."/mnt/data/homes" = {
    device = "data/homes";
    fsType = "zfs";
    options = ["zfsutil" "X-mount.mkdir"];
  };

  environment.systemPackages = with pkgs; [
    mergerfs
    bcachefs-tools
  ];

  # fileSystems."/mnt/disk1" = {
  #   device = "/dev/disk/by-id/ata-ST8000DM004-2CX188_ZCT19JFS-part1";
  #   fsType = "btrfs";
  #   options = ["compress=zstd" "noatime"];
  # };

  # fileSystems."/mnt/disk2" = {
  #   device = "/dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2WDVD-part1";
  #   fsType = "btrfs";
  #   options = ["compress=zstd" "noatime"];
  # };

  fileSystems."/mnt/storage" = {
    fsType = "bcachefs";
    device = "OLD_BLKID_UUID=e404faef-eb8c-4aae-97d2-4bb140c624c8";
    #device = "/dev/disk/by-id/ata-ST8000DM004-2CX188_ZCT19JFS-part1:/dev/disk/by-id/ata-ST4000VN008-2DR166_WDH2WDVD-part1";
    #options = ["cache.files=partial" "dropcacheonclose=true" "category.create=mfs" "moveonenospc=true"];
    options = ["compression=zstd" "nofail"];
  };

  swapDevices = [
    {device = "/dev/disk/by-uuid/5b0cde2c-d3f4-4d49-905f-5ada9910eda4";}
  ];

  networking.useDHCP = lib.mkDefault true;

  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
