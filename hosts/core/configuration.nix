{self, ...}: {
  imports =
    self.nixosSuites.core
    ++ [
      ./hardware-configuration.nix
    ];

  nixpkgs.hostPlatform = "x86_64-linux";

  networking.firewall.enable = true;
  services.fail2ban.enable = true;

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = "core";
  networking.domain = "";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com''];
  system.stateVersion = "23.11";
}
