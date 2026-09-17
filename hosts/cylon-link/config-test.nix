# Design invariants for cylon-link that a refactor could silently break,
# plus the kernel options the board needs. Neither half needs the full
# kernel build. See docs/superpowers/specs/2026-09-16-cylon-link-design.md.
{
  self,
  pkgs,
}: let
  inherit (pkgs) lib;
  c = self.nixosConfigurations.cylon-link.config;
  names = map (p: p.name or "") c.environment.systemPackages;
  check = cond: msg: lib.assertMsg cond "cylon-link: ${msg}";
in
  assert check (c.nixpkgs.hostPlatform.system == "armv7l-linux") "must target armv7l-linux";
  assert check (c.nixpkgs.buildPlatform.system == "x86_64-linux") "must be cross-compiled from x86_64-linux";
  assert check (self.deployTargets.cylon-link.system == "x86_64-linux") "just deploy only builds x86_64/aarch64 attributes";
  assert check (!(builtins.elem "cylon-link" (map (e: e.host) self.ciMatrix))) "must stay out of CI";
  assert check (!(c ? home-manager)) "must not get home-manager";
  assert check (!c.determinate.enable) "Determinate Nix has no armv7l build";
  assert check c.constellation.common.minimal "needs the minimal baseline";
  assert check (!builtins.any (n: lib.hasPrefix "ffmpeg" n) names) "the full tool list leaked in";
  assert check (c.nix.settings.max-jobs == 0) "the device must never build";
  assert check (!c.constellation.virtualization.enable) "virtualization is too heavy";
  assert check (!c.constellation.netdataClient.enable) "netdata is too heavy";
  assert check c.boot.loader.external.enable "must boot through the kexec chain";
  assert check (c.fileSystems."/".device == "/dev/disk/by-label/CYLON_ROOT") "root must be CYLON_ROOT";
  assert check (c.fileSystems."/boot/steamlink".device == "/dev/disk/by-label/CYLON_BOOT") "the install hook needs CYLON_BOOT mounted";
  assert check (c.hardware.deviceTree.name == "berlin2cd-valve-steamlink.dtb") "wrong device tree";
  assert check (c.system.build ? cylonLinkImage) "just flash-cylon-link needs the disk image";
  assert check (c.systemd.services ? cylon-link-register-store && c.systemd.services ? cylon-link-grow-root) "a flashed image must register its store and grow on first boot";
  assert check (c.services.tailscale.authKeyFile == c.sops.secrets.tailscale-key.path) "must join the tailnet unattended";
  assert check (c.sops.secrets.tailscale-key.sopsFile == c.constellation.sops.commonSopsFile) "the Tailscale key comes from common.yaml";
    pkgs.runCommand "cylon-link-config" {} ''
      config=${c.boot.kernelPackages.kernel.configfile}
      for opt in ARCH_BERLIN=y MACH_BERLIN_BG2CD=y USB_EHCI_HCD=y USB_CHIPIDEA_HOST=y \
                 PHY_BERLIN_USB=y USB_STORAGE=y BLK_DEV_SD=y EXT4_FS=y SERIAL_8250_DW=y \
                 KEXEC=y 'PXA168_ETH=[ym]'; do
        grep -qxE "CONFIG_$opt" "$config" || { echo "kernel config lacks CONFIG_$opt" >&2; exit 1; }
      done
      touch $out
    ''
