{
  config,
  pkgs,
  ...
}: {
  imports = [
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
    ./hardware-configuration.nix
    ./caddy.nix
    ./services.nix
  ];

  networking.nameservers = ["8.8.8.8" "1.1.1.1"];
  networking.hostId = "95760b5e";

  security.sudo.wheelNeedsPassword = false;

  networking.hostName = "oracle";
}
