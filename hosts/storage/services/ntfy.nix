{config, ...}: let
  vars = config.media.config;
in {
  media.gateway.services.ntfy = {
    port = 2586;
    settings.bypassAuth = true;
  };

  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.${vars.domain}";
      upstream-base-url = "https://ntfy.sh";
      listen-http = ":2586";
      behind-proxy = true;
      message-size-limit = "8k";
    };
  };
}
