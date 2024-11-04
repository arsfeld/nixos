{
  self,
  pkgs,
  config,
  ...
}: {
  imports =
    self.nixosSuites.base
    ++ [
      ./hardware-configuration.nix
    ];

  nixpkgs.hostPlatform = "aarch64-linux";

  services.tailscale.enable = true;

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = "oci-br";
  networking.domain = "subnet11032152.vcn11032152.oraclevcn.com";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com''];
  system.stateVersion = "23.11";
}
