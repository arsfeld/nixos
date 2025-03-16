{
  self,
  config,
  pkgs,
  ...
}: let
  mediaDomain = config.media.config.domain;
  ports = config.media.gateway.ports;
in {
  services.vaultwarden = {
    enable = true;
    config = {
      DOMAIN = "https://vault.${mediaDomain}";
      SIGNUPS_ALLOWED = true;
      ROCKET_ADDRESS = "0.0.0.0";
      ROCKET_PORT = ports.vault;
      USE_SENDMAIL = true;
      SENDMAIL_COMMAND = "${pkgs.system-sendmail}/bin/sendmail";
      SMTP_FROM = "admin@rosenfeld.one";
    };
  };
}
