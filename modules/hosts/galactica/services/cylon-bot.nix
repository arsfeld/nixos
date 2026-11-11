# cylon-bot: relays Claude Code hook events from every host to the ESP32 session board
# (an ESP32-S3 AMOLED) and the board's answers back. The hooks and the board both reach it at
# https://cylon-bot.arsfeld.one: through Cloudflare from outside, straight to Caddy on the
# LAN. It is public and token-gated: Authelia is bypassed because neither the board nor a hook
# can log in, so the bridge's own bearer tokens (sops, 256-bit) are the only gate. Approving a
# question runs nothing by itself, but treat the tokens as credentials all the same.
# Design: docs/superpowers/specs/2026-11-09-cylon-bot-design.md
# Plan: docs/superpowers/plans/2026-11-09-cylon-bot.md
{
  configurations.nixos.galactica.module = {
    config,
    pkgs,
    ...
  }: let
    port = 8590;
    secrets = config.sops.secrets;
  in {
    # The host token is declared for every host in modules/base/cylon-bot.nix; only this host
    # has the unit to restart (a restartUnits entry for a unit that does not exist fails the
    # whole activation, which is what happened on raider). The bridge reads its tokens at start.
    sops.secrets.cylon-bot-host-token.restartUnits = ["cylon-bot.service"];
    sops.secrets.cylon-bot-device-token.restartUnits = ["cylon-bot.service"];

    media.services.cylon-bot = {
      inherit port;
      host = "127.0.0.1";
      bypassAuth = true;
    };

    # The bridge was `claude-board` until 2026-11-10, with its state (timers.json, hermes-session)
    # in /var/lib/private/claude-board. This moves that directory to the new name once, before the
    # bridge first starts; systemd then re-owns it for the new DynamicUser. It does nothing once
    # the old directory is gone, and the whole unit can be deleted after galactica has deployed it.
    systemd.services.cylon-bot-state-migrate = {
      description = "Move claude-board state to cylon-bot";
      wantedBy = ["cylon-bot.service"];
      before = ["cylon-bot.service"];
      unitConfig.ConditionPathExists = "/var/lib/private/claude-board";
      serviceConfig.Type = "oneshot";
      script = ''
        new=/var/lib/private/cylon-bot
        if [ -e "$new" ] && [ -n "$(ls -A "$new")" ]; then
          echo "$new is not empty; leaving /var/lib/private/claude-board in place" >&2
          exit 0
        fi
        rm -rf "$new"
        mv /var/lib/private/claude-board "$new"
        rm -f /var/lib/claude-board
      '';
    };

    systemd.services.cylon-bot = {
      description = "cylon-bot: Claude Code session board relay";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      environment = {
        BRIDGE_LISTEN = "127.0.0.1:${toString port}";
        # %d is the unit's credentials directory.
        BRIDGE_HOST_TOKEN_FILE = "%d/host-token";
        BRIDGE_DEVICE_TOKEN_FILE = "%d/device-token";
        # Cloudflare cuts a proxied request at 100 s; stay well under it.
        BRIDGE_ASK_TIMEOUT_SECS = "60";
      };
      serviceConfig = {
        ExecStart = "${pkgs.cylon-bot-bridge}/bin/cylon-bot-bridge";
        DynamicUser = true;
        # Persistent timers ($STATE_DIRECTORY/timers.json) survive a restart.
        StateDirectory = "cylon-bot";
        LoadCredential = [
          "host-token:${secrets.cylon-bot-host-token.path}"
          "device-token:${secrets.cylon-bot-device-token.path}"
        ];
        Restart = "always";
        RestartSec = "5s";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}
