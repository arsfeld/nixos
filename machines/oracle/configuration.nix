{
  config,
  pkgs,
  ...
}: {
  imports = [
    ../../common/common.nix
    ../../common/services.nix
    ../../common/users.nix
    ../battlestar/rclone-mount.nix
    ./hardware-configuration.nix
    ./web.nix
    ./services.nix
  ];

  networking.nameservers = ["8.8.8.8" "1.1.1.1"];
  networking.hostId = "95760b5e";
  networking.firewall.enable = false;

  security.sudo.wheelNeedsPassword = false;
  networking.usePredictableInterfaceNames = true;

  networking.hostName = "oracle";
}
