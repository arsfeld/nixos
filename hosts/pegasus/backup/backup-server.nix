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

  # systemd sandboxing bind-mounts dataDir into the service namespace
  # and fails if the path doesn't exist yet. Create it explicitly;
  # RequiresMountsFor ensures mnt-storage.mount has succeeded before
  # the service runs, so these rules can't accidentally create the
  # directory on the root SSD.
  systemd.tmpfiles.rules = [
    "d /mnt/storage/backups 0755 root root -"
    "d /mnt/storage/backups/restic-server 0700 restic restic -"
  ];
}
