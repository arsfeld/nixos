{config, ...}: {
  sops.secrets."morphic-env" = {};

  # Morphic — ask.arsfeld.one. Reaches the host's system PostgreSQL (provisioned
  # via database.postgres below: trust auth over the podman bridge, passwordless)
  # and native SearXNG via host.containers.internal (provided automatically by
  # podman).
  media.services.ask = {
    port = 3000;
    image = "ghcr.io/miurla/morphic:latest";
    bypassAuth = true; # auth at the Cloudflare edge (galactica Authelia is down)
    tailscaleExposed = true; # ask.bat-boa.ts.net
    watchImage = true;
    container = {
      configDir = null; # morphic keeps state in postgres, not /config
      environmentFiles = [config.sops.secrets."morphic-env".path];
    };
    database.postgres = {name = "morphic";};
  };
}
