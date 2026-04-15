{...}: {
  services.restic.server = {
    enable = true;
    extraFlags = ["--no-auth"];
    dataDir = "/mnt/storage/backups/restic-server";
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [8000];

  # Block the server from starting if the data pool isn't mounted —
  # otherwise restic-rest-server would create its dataDir on the root
  # SSD and silently accept backups into the wrong place.
  systemd.services.restic-rest-server.unitConfig.RequiresMountsFor = "/mnt/storage";
}
