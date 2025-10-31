{
  imports = [
    ./ai.nix
    ./bcachefs-monitor.nix
    ./cloud-sync.nix
    ./db.nix
    ./develop.nix
    ./files.nix
    ./home.nix
    ./homepage.nix
    ./immich.nix
    ./infra.nix
    ./media.nix
    # ./metrics.nix  # Replaced by constellation.observability-hub module
    ./misc.nix
    ./qbittorrent-vpn.nix
    ./transmission-vpn.nix
    ./samba.nix
  ];
}
