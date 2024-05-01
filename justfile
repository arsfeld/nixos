

fmt: 
    nix fmt

args := "--skip-checks --auto-rollback false --keep-result"

boot HOST: fmt
    deploy {{ args }} --boot .#{{HOST}}

deploy HOST: fmt
    deploy {{ args }} .#{{HOST}}

r2s:
    ./r2s.sh