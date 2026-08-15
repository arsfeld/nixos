# Upstream yarr (nkanaev/yarr), not the arsfeld fork — see
# hosts/galactica/services/yarr.nix. pegasus has no Authelia and bypassAuth is
# set, so YARR_AUTH is the only thing standing in front of this instance.
{config, ...}: {
  sops.secrets."yarr-env" = {};

  media.services.yarr = {
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
