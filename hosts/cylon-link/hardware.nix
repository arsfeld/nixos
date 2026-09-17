# Valve Steam Link (2015): Marvell Berlin BG2CD, one Cortex-A9 core, 512 MB.
{pkgs, ...}: {
  # Cross-compiled on raider. nixpkgs caches nothing for armv7l, and a native
  # build on basestar spent 86 minutes without finishing the toolchain
  # (docs/superpowers/specs/2026-09-16-cylon-link-design.md).
  nixpkgs.hostPlatform = "armv7l-linux";
  nixpkgs.buildPlatform = "x86_64-linux";

  # multi_v7_defconfig already has every driver this board needs. autoModules
  # would build the rest of the tree as modules, which dominated the build.
  boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linuxPackages.kernel.override {autoModules = false;});
  boot.kernelParams = ["console=ttyS0,115200n8" "usbcore.autosuspend=-1"];
  hardware.deviceTree.name = "berlin2cd-valve-steamlink.dtb";

  # USB storage, SCSI disks and ext4 are built in. The default initrd list
  # names PC storage modules this kernel does not have.
  boot.initrd.includeDefaultModules = false;
  # The systemd initrd's TPM2 support asks for tpm-tis. This kernel leaves
  # CONFIG_TCG_TIS unset, and the board has no TPM to drive.
  boot.initrd.allowMissingModules = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/CYLON_ROOT";
    fsType = "ext4";
    options = ["noatime"];
  };

  # Wired only. The mwifiex SDIO radio works under this kernel but is out of
  # scope.
  networking.useNetworkd = true;
  networking.useDHCP = true;
}
