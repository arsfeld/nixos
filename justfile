

fmt: 
    nix fmt

args := "--skip-checks --auto-rollback false"

boot +HOST: fmt
    deploy {{ args }} --boot --targets .#{{HOST}}

deploy +HOST: fmt
    deploy {{ args }} --targets .#{{HOST}}

build HOST:
    nix build '.#nixosConfigurations.{{ HOST }}.config.system.build.toplevel'
    attic push system result

r2s:
    ./r2s.sh