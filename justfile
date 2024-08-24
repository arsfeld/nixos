

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
    ./r2s.sh
