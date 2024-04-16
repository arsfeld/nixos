

boot HOST:
    colmena apply --impure boot --on {{HOST}}

apply HOST:
    colmena apply --impure --on {{HOST}}

r2s:
    nix-build '<nixpkgs/nixos>' -A config.system.build.sdImage -I nixos-config=./machines/r2s/sd-image.nix