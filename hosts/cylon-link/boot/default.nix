# The NixOS half of cylon-link's boot chain. The firmware half, and the
# protocol between them, is documented in run.sh.
{
  config,
  lib,
  pkgs,
  ...
}: let
  p1 = "/boot/steamlink";

  # Adds kexec to Valve's 3.8.13 kernel, which lacks it. Built by
  # djmuted/steamlink-debian (GPL), which ships the binary without its source.
  # Byte-identical to the copy in the Debian image this host replaced.
  kexecModule = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/djmuted/steamlink-debian/216b58b6e9bb4ba20a9648d1ef089d7b6dbb58df/rootfs/boot/kexec_load.ko";
    hash = "sha256-sbinlkoG1+vNRRcLZWX22eNIxfyIXro65/yBj0BLGVY=";
  };

  # Static musl: it runs under the 3.8 kernel, which nixpkgs' glibc refuses.
  # Only the binary is copied: pkgsStatic kexec-tools propagates static
  # zlib/zstd dev outputs, whose build-platform references would land on the device.
  kexecStatic = pkgs.runCommand "kexec-static" {allowedReferences = [];} ''
    install -Dm755 ${pkgs.pkgsStatic.kexec-tools}/bin/kexec $out/bin/kexec
  '';

  bootToolFor = p:
    p.callPackage ./package.nix {
      kexec = "${kexecStatic}/bin/kexec";
      kexecModule = "${kexecModule}";
      dtbName = config.hardware.deviceTree.name;
    };
  bootTool = bootToolFor pkgs;
in {
  fileSystems.${p1} = {
    device = "/dev/disk/by-label/CYLON_BOOT";
    # CYLON_BOOT is ext3 so Valve's kernel can read it. The ext4 driver mounts
    # it without changing its on-disk features.
    fsType = "ext4";
    options = ["noatime"];
  };

  boot.loader.external = {
    enable = true;
    installHook = pkgs.writeShellScript "cylon-link-install-hook" ''
      exec ${lib.getExe bootTool} install "$1" ${p1}
    '';
  };

  # "Booted OK" means deployable, so wait for Tailscale. An entry this unit
  # never confirms is not retried on the next power cycle.
  systemd.services.cylon-link-boot-ok = {
    description = "Record this cylon-link boot entry as good";
    wantedBy = ["multi-user.target"];
    wants = ["network-online.target"];
    after = ["network-online.target" "tailscaled.service"];
    unitConfig.RequiresMountsFor = p1;
    path = [config.services.tailscale.package];
    # A switch must not re-run it: /proc/cmdline still describes the boot.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "6min";
    };
    script = ''
      for _ in $(seq 60); do
        if tailscale status >/dev/null 2>&1; then
          exec ${lib.getExe bootTool} confirm ${p1} /proc/cmdline
        fi
        sleep 5
      done
      echo "Tailscale never came up; this boot entry stays unconfirmed" >&2
      exit 1
    '';
  };

  # Build-platform copy for `just flash-cylon-link`.
  system.build.cylonLinkBoot = bootToolFor pkgs.buildPackages;
}
