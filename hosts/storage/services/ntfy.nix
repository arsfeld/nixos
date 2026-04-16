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

  # Publisher credential, consumed by every storage service that posts to
  # ntfy.arsfeld.one (image-watch, check-stock, claude-notify). owner =
  # arosenfeld + mode 0400 lets the user-mode claude-notify read it directly
  # while systemd services (run as root) can still load it via
  # EnvironmentFile.
  sops.secrets."ntfy-publisher-env" = {
    sopsFile = ../../../secrets/sops/ntfy-client.yaml;
    owner = "arosenfeld";
    mode = "0400";
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
