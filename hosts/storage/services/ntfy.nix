{config, ...}: let
  vars = config.media.config;
in {
  media.gateway.services.ntfy = {
    port = 2586;
    settings.bypassAuth = true;
  };

  # Auth users + ACLs are provisioned declaratively via environment
  # variables (ntfy >= v2.14.0 supports NTFY_AUTH_USERS / NTFY_AUTH_ACCESS
  # / NTFY_AUTH_DEFAULT_ACCESS). Declarative provisioning is authoritative:
  # removing a user from NTFY_AUTH_USERS deletes the DB row on restart.
  sops.secrets."ntfy-server-env" = {};

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
