#! /usr/bin/env bash

set -x

OUT=out

mkdir $OUT

nix-build '<nixpkgs/nixos>' --argstr system aarch64-linux -A config.system.build.sdImage -I nixos-config=machines/r2s/sd-image.nix
IMG_ZST=$(basename result/sd-image/*)
IMG="${IMG_ZST%.zst}"
unzstd -f result/sd-image/$IMG.zst -o $OUT/$IMG
#cp result/sd-image/$IMG $OUT/

nix build "github:EHfive/flakes#packages.aarch64-linux.ubootNanopiR2s"
#nix-build '<nixos/nixpkgs>' --argstr system aarch64-linux -A uboot_NanopiR4S
cp result/* $OUT/

chmod -R +rw $OUT

sfdisk --dump $OUT/$IMG

dd if=$OUT/idbloader.img of=$OUT/$IMG conv=fsync,notrunc bs=512 seek=64
dd if=$OUT/u-boot.itb of=$OUT/$IMG conv=fsync,notrunc bs=512 seek=16384

sfdisk --dump $OUT/$IMG

zstd -f --rm $OUT/$IMG

echo "Image built successfully?!"
echo ""
echo "Now burn the image with:"
echo "dd if=$OUT/$IMG of=/dev/mydev iflag=direct oflag=direct bs=16M status=progress"
echo "or compress it with:"
echo "tar -c -I 'xz -9 -T0' -f nanopi-nixos-$(date --rfc-3339=date).img.xz $OUT/$IMG"

