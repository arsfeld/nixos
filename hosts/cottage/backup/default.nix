{
  pkgs,
  config,
  self,
  ...
}: {
  imports = [
    ./backup-server.nix
  ];

  # Garage secrets are configured in ../services/default.nix
}
