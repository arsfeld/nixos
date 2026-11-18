# zellij's built-in web client, at https://raider.bat-boa.ts.net/ (tailnet only).
#
# zellij listens on loopback only; `tailscale serve` terminates TLS and proxies
# to it, so zellij needs no certificate of its own. The page is a full shell,
# and its login token is the only gate besides tailnet membership: never put
# this behind `tailscale funnel`.
#
# Log in with a token from `zellij web --create-token` (shown once; list or
# revoke with `--list-tokens` / `--revoke-token <name>`). A session is at
# /<session-name>, e.g. /main. web_sharing = "on" in home/home.nix shares
# every session on raider, so existing ones can be attached without sharing
# each by hand.
#
# The root used to proxy the job-hunt dashboard (127.0.0.1:8787, a hand-made
# user unit outside this repo); this replaced that mapping.
{
  configurations.nixos.raider.module = {
    config,
    pkgs,
    ...
  }: let
    port = 8082;
  in {
    systemd.user.services.zellij-web = {
      description = "zellij web client";
      unitConfig.ConditionUser = "arosenfeld";
      wantedBy = ["default.target"];
      serviceConfig = {
        # The real binary, not home.nix's zellijGuarded wrapper: this creates
        # no session, and the guard only concerns session creation.
        ExecStart = "${pkgs.zellij}/bin/zellij web --start --ip 127.0.0.1 --port ${toString port}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # tailscaled keeps serve config in its own state, so this only has to
    # assert it; re-running is idempotent and overwrites whatever held "/".
    systemd.services.zellij-web-serve = {
      description = "Expose zellij web on the tailnet via tailscale serve";
      after = ["tailscaled.service" "network-online.target"];
      wants = ["tailscaled.service" "network-online.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.services.tailscale.package}/bin/tailscale serve --bg --https=443 http://127.0.0.1:${toString port}";
        # tailscaled may still be logging in at boot.
        Restart = "on-failure";
        RestartSec = 10;
      };
    };
  };
}
