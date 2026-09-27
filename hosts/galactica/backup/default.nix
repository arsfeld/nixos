{
  imports = [
    ./backup-server.nix
    ./backrest-client.nix
    ./rustic-ovh.nix
    ./rustic.nix
  ];

  constellation.backupSummary.enable = true;
}
