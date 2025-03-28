fmt: 
    nix fmt

args := "--skip-checks"

boot +HOST: 
    deploy {{ args }} --boot --targets .#{{HOST}}

deploy +HOST: 
    deploy {{ args }} --targets .#{{HOST}}

build HOST:
    nix build '.#nixosConfigurations.{{ HOST }}.config.system.build.toplevel'
    attic push system result

r2s:
    #!/usr/bin/env bash
    set -e
    OUT=out
    mkdir -p $OUT
    
    # Build NixOS SD image and U-Boot for NanopiR2s
    nix build --impure --expr '(import <nixpkgs/nixos> { system = "aarch64-linux"; configuration = ./hosts/r2s/sd-image.nix; }).config.system.build.sdImage'
    nix build "github:EHfive/flakes#packages.aarch64-linux.ubootNanopiR2s"
    
    # Extract and prepare files
    IMG_ZST=$(basename result/sd-image/*)
    IMG="${IMG_ZST%.zst}"
    unzstd -f result/sd-image/$IMG_ZST -o $OUT/$IMG
    cp result/* $OUT/
    chmod -R +rw $OUT
    
    # Write bootloader files to specific sectors
    sfdisk --dump $OUT/$IMG
    dd if=$OUT/idbloader.img of=$OUT/$IMG conv=fsync,notrunc bs=512 seek=64
    dd if=$OUT/u-boot.itb of=$OUT/$IMG conv=fsync,notrunc bs=512 seek=16384
    
    # Compress the final image
    zstd -f --rm $OUT/$IMG
    
    echo "✅ Image built successfully: $OUT/$IMG.zst"
    echo ""
    echo "To burn the image: dd if=$OUT/$IMG.zst of=/dev/mydev iflag=direct oflag=direct bs=16M status=progress"
    echo "To archive: tar -c -I 'xz -9 -T0' -f nanopi-nixos-$(date --rfc-3339=date).img.xz $OUT/$IMG.zst"
