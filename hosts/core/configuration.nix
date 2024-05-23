{
  self,
  pkgs,
  config,
  ...
}: {
  imports =
    self.nixosSuites.core-vm
    ++ [
      ./hardware-configuration.nix
    ];

  nixpkgs.hostPlatform = "x86_64-linux";

  networking.firewall.enable = true;
  services.fail2ban.enable = true;

  age.secrets.attic-token.file = ../../secrets/attic-token.age;

  age.secrets.attic-server = {
    file = ../../secrets/attic-server.age;
    mode = "444";
  };

  systemd.services.atticd = {
    enable = true;
    description = "Attic Server";
    serviceConfig = {
      ExecStart = "${pkgs.attic-server}/bin/atticd -f ${config.age.secrets.attic-server.path} --mode monolithic";
      User = "atticd";
      Group = "atticd";
      DynamicUser = true;
      ProtectHome = true;
      StateDirectory = "atticd";
      ReadWritePaths = ["/var/lib/atticd"];
    };
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
  };

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = "core";
  networking.domain = "";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com''];
  system.stateVersion = "23.11";
}
