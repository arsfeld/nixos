

r2s:
    nix-build '<nixpkgs/nixos>' -A config.system.build.sdImage -I nixos-config=./machines/r2s/sd-image.nix