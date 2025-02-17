{
  self,
  config,
  pkgs,
  ...
}: {
  imports = [
    ./services/auth.nix
    ./services/development.nix
    ./services/utility.nix
    ./services/vault.nix
  ];

  age.secrets.tailscale-key.file = "${self}/secrets/tailscale-key.age";

  services.tsnsrv = {
    enable = true;
    defaults = {
      tags = ["tag:service"];
      authKeyPath = config.age.secrets.tailscale-key.path;
    };
  };

  # users.users.beszel-agent = {
  #   group = "beszel-agent";
  #   home = "/var/lib/beszel-agent";
  #   isSystemUser = true;
  #   createHome = true;
  # };

  # users.groups.beszel-agent.name = "beszel-agent";

  # systemd.services.beszel-agent = {
  #   wantedBy = ["multi-user.target"];
  #   after = ["network.target"];
  #   serviceConfig = {
  #     Environment = [
  #       "PORT=45876"
  #       "KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGKIjUSMdRqYMmZopjoXBVbEW2SpjE4mxrPclsnQCvW9'"
  #     ];
  #     User = "beszel-agent";
  #     ExecStart = "${pkgs.beszel}/bin/beszel-agent";
  #     WorkingDirectory = "/var/lib/beszel-agent";
  #   };
  # };
}
