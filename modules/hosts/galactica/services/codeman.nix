# https://codeman.arsfeld.one: the Codeman agent dashboard, which runs on
# raider. Gateway-only, behind Authelia; raider's tailscale serve forwards
# :8443 to Codeman. Why it is built this way, and what it exposes:
# modules/hosts/raider/codeman.nix.
{
  configurations.nixos.galactica.module = {config, ...}: {
    media.services.codeman = {
      host = "raider.bat-boa.ts.net";
      port = 8443;
    };

    # Codeman's own login still guards raider:8443 against the rest of the
    # tailnet, but on the public path Authelia is the only login: Caddy sends
    # Codeman's credentials itself, replacing any Authorization the client
    # sent. It runs after forward_auth (Caddy's directive order), so Authelia
    # never sees it. Same password as `codeman-env` in raider.yaml, as
    # CODEMAN_BASIC_AUTH=base64("admin:<password>"); change both together.
    sops.secrets."codeman-caddy-env" = {
      owner = config.services.caddy.user;
      mode = "0400";
      restartUnits = ["caddy.service"];
    };
    services.caddy.environmentFile = config.sops.secrets."codeman-caddy-env".path;
    services.caddy.virtualHosts."codeman.${config.media.config.domain}".extraConfig = ''
      request_header Authorization "Basic {env.CODEMAN_BASIC_AUTH}"
    '';
  };
}
