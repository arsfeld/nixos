{
  config,
  lib,
  ...
}: {
  sops.secrets."linkding-env" = {};

  media.services.linkding = {
    # bootstrap chowns /etc/linkding/data: CHOWN; writes data/assets owned by media: DAC_OVERRIDE, FOWNER; drops to www-data: SETUID, SETGID.
    container.hardening.caps = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID"];
    port = 9090;
    image = "ghcr.io/sissbruecker/linkding:latest";
    bypassAuth = true; # linkding has its own auth; browser extension/REST API need direct access
    tailscaleExposed = true;
    container = {
      exposePort = 9090;
      configDir = "/etc/linkding/data";
      environmentFiles = [
        config.sops.secrets."linkding-env".path
      ];
    };
  };
}
