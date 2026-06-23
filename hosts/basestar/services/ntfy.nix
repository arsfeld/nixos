# ntfy server — temporary failover home while galactica is down.
#
# Normally lives on galactica (services.ntfy-sh) and is served at
# ntfy.arsfeld.one via the gateway. While galactica is down we run it here so
# finance-tracker (and anything else publishing to ntfy.arsfeld.one) keeps
# working: basestar already runs a cloudflared connector for the same
# arsfeld.one tunnel, so ntfy.arsfeld.one resolves here. bypassAuth keeps it
# reachable without galactica's Authelia.
#
# Auth users + ACLs are provisioned declaratively via NTFY_AUTH_* env vars
# (ntfy >= v2.14.0). restartUnits forces an ntfy-sh restart when the secret
# changes so rotations/default-access flips actually take effect.
{
  self,
  config,
  lib,
  ...
}: let
  vars = config.media.config;
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
in
  lib.mkMerge [
    (mkService "ntfy" {
      port = 2586;
      bypassAuth = true;
    })

    {
      sops.secrets."ntfy-server-env" = {
        restartUnits = ["ntfy-sh.service"];
      };

      services.ntfy-sh = {
        enable = true;
        environmentFile = config.sops.secrets."ntfy-server-env".path;
        settings = {
          base-url = "https://ntfy.${vars.domain}";
          upstream-base-url = "https://ntfy.sh";
          listen-http = ":2586";
          behind-proxy = true;
          message-size-limit = "8k";
        };
      };
    }
  ]
