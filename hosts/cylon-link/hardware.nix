# Valve Steam Link (2015): Marvell Berlin BG2CD, one Cortex-A9 core, 512 MB.
{
  lib,
  pkgs,
  ...
}: {
  # Cross-compiled on raider. nixpkgs caches nothing for armv7l, and a native
  # build on basestar spent 86 minutes without finishing the toolchain
  # (docs/superpowers/specs/2026-09-16-cylon-link-design.md).
  nixpkgs.hostPlatform = "armv7l-linux";
  nixpkgs.buildPlatform = "x86_64-linux";

  # multi_v7_defconfig already has every driver this board needs. autoModules
  # would build the rest of the tree as modules, which dominated the build.
  # What the defconfig lacks is the fleet's networking: no TUN for tailscaled
  # and no netfilter at all, so the nftables firewall cannot load either.
  # These are exactly what nixos-fw's ruleset (inet table, fib, ct) and
  # tailscaled's own nftables chains (nat postrouting, masquerade) use.
  boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linuxPackages.kernel.override {
    autoModules = false;
    structuredExtraConfig = with lib.kernel; {
      TUN = module;
      NF_CONNTRACK = module;
      NF_NAT = module;
      NF_TABLES = module;
      NF_TABLES_INET = yes;
      NF_TABLES_IPV4 = yes;
      NF_TABLES_IPV6 = yes;
      NFT_CT = module;
      NFT_FIB_IPV4 = module;
      NFT_FIB_IPV6 = module;
      NFT_FIB_INET = module;
      NFT_NAT = module;
      NFT_MASQ = module;
    };
  });
  boot.kernelParams = ["console=ttyS0,115200n8" "usbcore.autosuspend=-1"];
  hardware.deviceTree.name = "berlin2cd-valve-steamlink.dtb";

  # USB storage, SCSI disks and ext4 are built in. The default initrd list
  # names PC storage modules this kernel does not have.
  boot.initrd.includeDefaultModules = false;
  # Except the reset controller, which Kconfig builds as a module. The USB
  # PHY takes its reset from it and defers until it loads, so without it the
  # stick never appears and the initrd waits for CYLON_ROOT forever.
  boot.initrd.kernelModules = ["reset-berlin"];
  # The board has no TPM, and this kernel does not build tpm-tis
  # (CONFIG_TCG_TIS is unset), which the initrd's TPM2 support would load.
  boot.initrd.systemd.tpm2.enable = false;

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
