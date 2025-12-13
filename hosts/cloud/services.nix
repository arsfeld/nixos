{
  self,
  config,
  ...
}: {
  imports = [
    ./services/auth.nix
    ./services/development.nix
    ./services/mosquitto.nix
    ./services/owntracks.nix
    ./services/rustdesk.nix
    ./services/utility.nix
    ./services/vault.nix
  ];

  age.secrets.tailscale-key.file = "${self}/secrets/tailscale-key.age";
  age.secrets.tailscale-env.file = "${self}/secrets/tailscale-env.age";

  # tsnsrv re-enabled - provides Tailscale node management for cloud services (task-100)
  # Runs alongside storage host's tsnsrv to expose cloud services via Tailscale
  services.tsnsrv = {
    enable = true;
    separateProcesses = true; # Create individual systemd service per tsnsrv service
    prometheusAddr = "127.0.0.1:9500"; # Moved from 9099 to avoid conflict with OpenCloud (uses 9100-9300)
    defaults = {
      tags = ["tag:service"];
      authKeyPath = config.age.secrets.tailscale-key.path;
      ephemeral = true;
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
