{
  config,
  lib,
  ...
}: {
  sops.secrets."linkding-env" = {};

  media.services.linkding = {
    # Probe-verified.
    # CHOWN: bootstrap chowns /etc/linkding/data (chown EPERM seen).
    # DAC_OVERRIDE: writes data/assets owned by media (mkdir permission denied seen).
    # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
    # SETUID, SETGID: bootstrap drops to www-data (precautionary; the drop itself was not individually tested).
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
