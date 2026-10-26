# Upstream yarr (nkanaev/yarr), not the arsfeld fork — see
# hosts/galactica/services/yarr.nix. pegasus has no Authelia and bypassAuth is
# set, so YARR_AUTH is the only thing standing in front of this instance.
{config, ...}: {
  sops.secrets."yarr-env" = {};

  media.services.yarr = {
    # Probe-verified: root process writes /data owned by media (5000); with no caps sqlite fails "attempt to write a readonly database".
    # DAC_OVERRIDE: write dirs/files owned by another uid.
    # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
    container.hardening.caps = ["DAC_OVERRIDE" "FOWNER"];
    port = 7070;
    image = "ghcr.io/nkanaev/yarr:latest";
    bypassAuth = true;
    container = {
      exposePort = 7070;
      configDir = "/data";
      environmentFiles = [
        config.sops.secrets."yarr-env".path
      ];
    };
  };
}
