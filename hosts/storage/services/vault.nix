{
  self,
  config,
  pkgs,
  ...
}: let
  mediaDomain = config.media.config.domain;
  port = 8002;
in {
  media.gateway.services.vault = {
    inherit port;
    exposeViaTailscale = true;
    settings.bypassAuth = true;
  };

  services.vaultwarden = {
    enable = true;
    config = {
      DOMAIN = "https://vault.${mediaDomain}";
      SIGNUPS_ALLOWED = true;
      ROCKET_ADDRESS = "0.0.0.0";
      ROCKET_PORT = port;
      USE_SENDMAIL = true;
      SENDMAIL_COMMAND = "${pkgs.system-sendmail}/bin/sendmail";
      SMTP_FROM = "admin@rosenfeld.one";
    };
  };
}
