{self, ...}: {
  imports = [
    ./hardware-configuration.nix
  ];

  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = true;
  };

  nixpkgs.hostPlatform = "aarch64-linux";

  services.tailscale.enable = true;

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = "cloud-br";
  networking.domain = "subnet11032152.vcn11032152.oraclevcn.com";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com''];
  system.stateVersion = "23.11";
}
