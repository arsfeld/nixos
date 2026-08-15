# Upstream yarr (nkanaev/yarr), not the arsfeld fork.
#
# The fork only added a Google Reader API (/reader/, /accounts/ClientLogin) for
# NetNewsWire sync, and was 267 commits behind upstream. Same entrypoint, same
# 7070, same /data/yarr.db, so the database carries over untouched — but Google
# Reader sync is gone; feed readers must use Fever instead.
#
# YARR_AUTH is what authenticates Fever: fever.go hashes md5(user:pass) into the
# api_key, and with no credentials set feverAuth() lets everyone in. Since
# /fever/ bypasses Authelia (services/auth.nix), this secret is the only thing
# guarding it.
{config, ...}: {
  sops.secrets."yarr-env" = {};

  media.services.yarr = {
    port = 7070;
    image = "ghcr.io/nkanaev/yarr:latest";
    tailscaleExposed = true;
    container = {
      exposePort = 7070;
      configDir = "/data";
      environmentFiles = [
        config.sops.secrets."yarr-env".path
      ];
    };
  };
}
