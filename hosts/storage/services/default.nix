{
  imports = [
    ./ai.nix
    # ./caddy-tailscale-test.nix  # Temporarily disabled - conflicts with media gateway globalConfig
    ./cloud-sync.nix
    ./db.nix
    ./develop.nix
    ./files.nix
    ./home.nix
    ./homepage.nix
    ./immich.nix
    ./infra.nix
    ./media.nix
    ./metrics.nix
    ./misc.nix
    ./samba.nix
  ];
}
