

fmt: 
    nix fmt

boot HOST: fmt
    deploy --skip-checks --auto-rollback false --boot .#{{HOST}}

deploy HOST: fmt
    deploy --skip-checks --auto-rollback false .#{{HOST}}

r2s:
    nix-build '<nixpkgs/nixos>' -A config.system.build.sdImage -I nixos-config=./machines/r2s/sd-image.nix