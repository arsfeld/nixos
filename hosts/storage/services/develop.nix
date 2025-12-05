{
  config,
  self,
  ...
}: let
  vars = config.media.config;
in {
  # Forgejo OIDC secret (client secret for Authelia)
  age.secrets.forgejo-oidc-secret = {
    file = "${self}/secrets/forgejo-oidc-secret.age";
    mode = "400";
    owner = "forgejo";
  };
  services.code-server = {
    enable = true;
    user = "arosenfeld";
    host = "0.0.0.0";
    port = 4444;
    auth = "none";
    proxyDomain = "code.${vars.domain}";
  };

  services.forgejo = {
    enable = true;
    settings = {
      DEFAULT = {
        APP_NAME = "Forgejo";
      };
      server = {
        ROOT_URL = "https://forgejo.${vars.domain}/";
        HTTP_PORT = 3001;
        DOMAIN = "forgejo.${vars.domain}";
      };
      actions = {
        ENABLED = "true";
      };
      # OAuth2/OIDC settings for Authelia integration
      openid = {
        ENABLE_OPENID_SIGNIN = false; # Disable legacy OpenID
        ENABLE_OPENID_SIGNUP = true; # Allow OIDC registration
        WHITELISTED_URIS = "auth.${vars.domain}"; # Whitelist Authelia
      };
      service = {
        DISABLE_REGISTRATION = false; # Needed for auto-registration via OIDC
        ALLOW_ONLY_EXTERNAL_REGISTRATION = true; # Only allow OIDC registration
        SHOW_REGISTRATION_BUTTON = false; # Hide manual registration button
      };
      oauth2_client = {
        ENABLE_AUTO_REGISTRATION = true; # Auto-create accounts from OIDC
        ACCOUNT_LINKING = "auto"; # Auto-link by email/username
        UPDATE_AVATAR = true; # Sync avatar from OIDC
        USERNAME = "nickname"; # Use nickname claim for username
      };
    };
  };
}
