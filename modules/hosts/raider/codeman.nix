# Codeman: a web dashboard that starts and shows agent sessions (claude, agy,
# ...) on raider, each in its own tmux session. Public at
# https://codeman.arsfeld.one. Spec:
# docs/superpowers/specs/2026-11-21-codeman-dashboard-design.md
#
#   Cloudflare -> galactica cloudflared -> Caddy + Authelia (one_factor)
#     -> raider.bat-boa.ts.net:8443 (tailscale serve, raw TCP over WireGuard)
#     -> Codeman on 127.0.0.1:8594 (this user unit) -> tmux -> claude / agy
#
# This is a public shell. Claude sessions it starts run with Codeman's default
# --dangerously-skip-permissions, so whoever gets past both logins has an
# unattended agent on raider as arosenfeld. Authelia guards the public path;
# CODEMAN_PASSWORD (user `admin`) guards :8443, which every tailnet peer
# reaches directly, past Authelia (tailscale0 is trusted fleet-wide). It is
# not optional. Galactica's Caddy sends it on the public path
# (`codeman-caddy-env`, galactica/services/codeman.nix), so a browser there
# sees only Authelia. Ten failed logins lock out the client IP for 15
# minutes, and every proxied client is 127.0.0.1 here, so a lockout locks out
# everyone.
#
# Sessions live in tmux under arosenfeld's user manager (lingering is on), so
# restarting this unit or switching raider leaves them running; a reboot ends
# them.
{
  configurations.nixos.raider.module = {
    config,
    lib,
    pkgs,
    ...
  }: let
    port = 8594;
    tailnetPort = 8443;
  in {
    sops.secrets."codeman-env" = {
      owner = "arosenfeld";
      mode = "0400";
    };

    systemd.user.services.codeman = {
      description = "Codeman agent dashboard";
      unitConfig.ConditionUser = "arosenfeld";
      wantedBy = ["default.target"];
      environment = {
        # *.ts.net is trusted by Codeman already; the public name is not.
        CODEMAN_ALLOWED_HOSTS = "codeman.arsfeld.one";
        # The same claude and agy a terminal gets: home-manager installs into
        # the user's nix profile, not /etc/profiles.
        PATH = lib.mkForce "${config.users.users.arosenfeld.home}/.nix-profile/bin:/run/wrappers/bin:/run/current-system/sw/bin";
      };
      serviceConfig = {
        # Binds 127.0.0.1 by default.
        ExecStart = "${lib.getExe pkgs.codeman} web --port ${toString port}";
        EnvironmentFile = config.sops.secrets."codeman-env".path;
        Restart = "on-failure";
        RestartSec = 5;
        # Codeman's tmux server (socket `-L codeman`) is spawned inside this
        # unit's cgroup; the default control-group kill took every session
        # with it on a restart. As in Codeman's own generated unit, signal
        # only the server.
        KillMode = "process";
        LimitNOFILE = 65536;
      };
    };

    # Beside zellij-web's `--https=443` mapping (zellij-web.nix); a different
    # port, so neither overwrites the other.
    #
    # Raw TCP, not `--http`: an HTTP serve handler matches on the Host header
    # (raider / raider.bat-boa.ts.net only), so galactica's proxied requests,
    # which carry Host codeman.arsfeld.one, got a 404 from tailscaled. The
    # gateway has no way to rewrite Host, and Codeman must stay on loopback:
    # raider's firewall is off, so any other bind is on the LAN too, and its
    # hook endpoints only skip the login for loopback clients.
    systemd.services.codeman-serve = {
      description = "Expose Codeman on the tailnet via tailscale serve";
      after = ["tailscaled.service" "network-online.target"];
      wants = ["tailscaled.service" "network-online.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.services.tailscale.package}/bin/tailscale serve --bg --tcp=${toString tailnetPort} tcp://127.0.0.1:${toString port}";
        # tailscaled keeps serve config in its own state: without this, deleting
        # the module would leave :8443 forwarding to a dead port. A switch that
        # restarts the unit runs ExecStart again right after.
        ExecStop = "${config.services.tailscale.package}/bin/tailscale serve --tcp=${toString tailnetPort} off";
        Restart = "on-failure";
        RestartSec = 10;
      };
    };
  };
}
