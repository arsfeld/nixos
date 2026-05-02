{config, ...}: let
  hubPort = 8090;
in {
  # Beszel hub: lightweight server monitoring web UI.
  # Agents on monitored hosts push metrics over an SSH tunnel back to the hub.
  services.beszel.hub = {
    enable = true;
    host = "0.0.0.0";
    port = hubPort;
  };

  # Beszel ships its own auth (PocketBase) and is wired up to Authelia OIDC
  # via the UI, so bypass Authelia at the gateway.
  media.gateway.services.beszel = {
    port = hubPort;
    settings.bypassAuth = true;
  };

  # OIDC: PocketBase stores OAuth provider config in its DB, not env vars,
  # so this is a one-time UI step. The Authelia client (`beszel`) is already
  # registered in the `authelia-secrets` sops blob.
  #
  # In the Beszel admin UI, Settings → Auth providers → OpenID Connect:
  #   Display name:   Authelia
  #   Client ID:      beszel
  #   Client secret:  (from `authelia-secrets`, key `client_secret`)
  #   Display name field: name
  #   Username field:     preferred_username
  #   Auth URL:           https://auth.arsfeld.one/api/oidc/authorization
  #   Token URL:          https://auth.arsfeld.one/api/oidc/token
  #   User info URL:      https://auth.arsfeld.one/api/oidc/userinfo
  # Redirect URI registered in Authelia: https://beszel.arsfeld.one/api/oauth2-redirect

  # Bootstrapping the agent requires the hub's SSH public key, which is only
  # generated on first hub start. After deploying the hub:
  #   1. visit https://beszel.${domain}, create the admin user
  #   2. "Add system" in the UI to reveal the SSH public key + universal token
  #   3. store `KEY=ssh-ed25519 ...` in sops secret `beszel-agent-env`
  #   4. enable the storage-local agent block below
  #
  # services.beszel.agent = {
  #   enable = true;
  #   environmentFile = config.sops.secrets."beszel-agent-env".path;
  #   environment.LISTEN = "127.0.0.1:45876";
  # };
  # sops.secrets."beszel-agent-env" = {
  #   restartUnits = ["beszel-agent.service"];
  # };
}
