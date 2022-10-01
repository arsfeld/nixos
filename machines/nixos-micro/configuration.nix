{...}: {
  imports = [
    ../../common/common.nix
    ../../common/users.nix
    ./hardware-configuration.nix
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];

  services.tailscale.enable = true;

  boot.cleanTmpDir = true;
  zramSwap.enable = true;
  networking.hostName = "nixos-micro";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com"
  ];
}
