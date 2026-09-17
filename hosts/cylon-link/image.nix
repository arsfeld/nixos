# cylon-link's flashable disk image and the first-boot units it relies on.
# `just flash-cylon-link` writes it with dd. The Kingston stick manages about
# 46 KB/s at small scattered writes, so copying a store onto it file by file
# takes hours, while one sequential write takes about a minute. Modelled on
# nixpkgs' sd-image.nix, with an ext3 CYLON_BOOT partition instead of a FAT
# firmware partition.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  inherit (config.system.build) toplevel;
  registration = "/nix-path-registration";

  rootfs = pkgs.callPackage (modulesPath + "/../lib/make-ext4-fs.nix") {
    storePaths = [toplevel];
    compressImage = true;
    volumeLabel = "CYLON_ROOT";
    # The host key is written after flashing, never into the store. This only
    # creates its directory.
    populateImageCommands = ''
      mkdir -p ./files/etc/ssh
    '';
  };
in {
  system.build.cylonLinkImage =
    pkgs.runCommand "cylon-link.img.zst" {
      nativeBuildInputs = with pkgs.buildPackages; [e2fsprogs.bin fakeroot libfaketime util-linux zstd];
    } ''
      # p1: what Valve's firmware reads, staged exactly as the NixOS install
      # hook stages it. No good entry: if the first boot fails, the stock
      # firmware stays up.
      mkdir p1
      ${lib.getExe config.system.build.cylonLinkBoot} install ${toplevel} p1
      truncate -s 1G p1.img
      faketime -f "1970-01-01 00:00:01" fakeroot mkfs.ext3 -q -L CYLON_BOOT -d p1 p1.img

      zstd -d --no-progress ${rootfs} -o p2.img

      start=2048
      p1Sectors=$(( $(stat -c %s p1.img) / 512 ))
      p2Sectors=$(( $(stat -c %s p2.img) / 512 ))
      truncate -s $(( (start + p1Sectors + p2Sectors) * 512 )) disk.img
      sfdisk --no-reread --no-tell-kernel disk.img <<EOF
      label: dos
      start=$start, size=$p1Sectors, type=83
      start=$(( start + p1Sectors )), size=$p2Sectors, type=83
      EOF
      dd conv=notrunc bs=4M oflag=seek_bytes if=p1.img of=disk.img seek=$(( start * 512 ))
      dd conv=notrunc bs=4M oflag=seek_bytes if=p2.img of=disk.img seek=$(( (start + p1Sectors) * 512 ))
      zstd -T$NIX_BUILD_CORES --no-progress disk.img -o $out
    '';

  # First boot of a flashed image: grow CYLON_ROOT over the rest of the
  # stick. From sd-image.nix, except that the partition number comes from
  # sysfs. sd-image derives it from the minor number, which is only right for
  # the first disk.
  systemd.services.cylon-link-grow-root = {
    description = "Grow CYLON_ROOT to fill the USB stick";
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = registration;
    };
    wantedBy = ["sysinit.target"];
    before = ["sysinit.target" "shutdown.target" "cylon-link-register-store.service"];
    after = ["local-fs.target"];
    conflicts = ["shutdown.target"];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [pkgs.util-linux pkgs.e2fsprogs];
    script = ''
      part=$(readlink -f "$(findmnt -n -o SOURCE /)")
      disk=$(lsblk -npo PKNAME "$part")
      num=$(cat "/sys/class/block/''${part##*/}/partition")
      echo ",+," | sfdisk -N"$num" --no-reread "$disk"
      partx -u --nr "$num" "$disk"
      resize2fs "$part"
    '';
  };

  # First boot of a flashed image: load the store registration that
  # make-ext4-fs wrote, and create the system profile. From sd-image.nix.
  systemd.services.cylon-link-register-store = {
    description = "Register the flashed Nix store";
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = registration;
    };
    wantedBy = ["sysinit.target"];
    before = ["sysinit.target" "shutdown.target" "nix-daemon.socket" "nix-daemon.service"];
    after = ["local-fs.target"];
    conflicts = ["shutdown.target"];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${lib.getExe' config.nix.package.out "nix-store"} --load-db < ${registration}
      touch /etc/NIXOS
      ${lib.getExe' config.nix.package.out "nix-env"} -p /nix/var/nix/profiles/system --set /run/current-system
      rm -f ${registration}
    '';
  };
}
