{
  self,
  config,
  pkgs,
  ...
}: let
  mediaDomain = config.media.config.domain;
  services = config.media.gateway.services;
in {
  services.vaultwarden = {
    enable = true;
    config = {
      DOMAIN = "https://vault.${mediaDomain}";
      SIGNUPS_ALLOWED = true;
      ROCKET_ADDRESS = "0.0.0.0";
      ROCKET_PORT = services.vault.port;
      USE_SENDMAIL = true;
      SENDMAIL_COMMAND = "${pkgs.system-sendmail}/bin/sendmail";
      SMTP_FROM = "admin@rosenfeld.one";
    };
  };
}
