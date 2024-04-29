

fmt: 
    nix fmt

args := "--skip-checks --auto-rollback false --keep-result"

boot HOST: fmt
    deploy {{ args }} --boot .#{{HOST}}

deploy HOST: fmt
    deploy {{ args }} .#{{HOST}}

r2s:
    nix-build '<nixpkgs/nixos>' -A config.system.build.sdImage -I nixos-config=./machines/r2s/sd-image.nix