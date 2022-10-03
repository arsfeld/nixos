{...}: {
  imports = [
    ../../common/common.nix
    ../../common/users.nix
    ./hardware-configuration.nix
    ./sites/arsfeld.one.nix
  ];

  services.tailscale.enable = true;

  users.users.caddy.extraGroups = ["acme"];

  security.acme = {
    acceptTerms = true;
  };

  services.caddy = {
    enable = true;
  };

  networking.firewall.enable = false;
  boot.cleanTmpDir = true;
  zramSwap.enable = true;
  networking.hostName = "micro";
}
