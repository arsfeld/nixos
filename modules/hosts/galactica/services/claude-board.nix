# claude-board: relays Claude Code hook events from every host to the ESP32 session board
# (an ESP32-S3 AMOLED) and the board's answers back. The hooks and the board both reach it at
# https://claude-board.arsfeld.one: through Cloudflare from outside, straight to Caddy on the
# LAN. It is public and token-gated: Authelia is bypassed because neither the board nor a hook
# can log in, so the bridge's own bearer tokens (sops, 256-bit) are the only gate. Approving a
# question runs nothing by itself, but treat the tokens as credentials all the same.
# Design: docs/superpowers/specs/2026-11-09-claude-board-design.md
# Plan: docs/superpowers/plans/2026-11-09-claude-board.md
{
  configurations.nixos.galactica.module = {
    config,
    pkgs,
    ...
  }: let
    port = 8590;
    secrets = config.sops.secrets;
  in {
    # The host token is declared for every host in modules/base/claude-board.nix; only this host
    # has the unit to restart (a restartUnits entry for a unit that does not exist fails the
    # whole activation, which is what happened on raider). The bridge reads its tokens at start.
    sops.secrets.claude-board-host-token.restartUnits = ["claude-board.service"];
    sops.secrets.claude-board-device-token.restartUnits = ["claude-board.service"];

    media.services.claude-board = {
      inherit port;
      host = "127.0.0.1";
      bypassAuth = true;
    };

    systemd.services.claude-board = {
      description = "claude-board: Claude Code session board relay";
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
        ExecStart = "${pkgs.claude-board-bridge}/bin/claude-board-bridge";
        DynamicUser = true;
        # Persistent timers ($STATE_DIRECTORY/timers.json) survive a restart.
        StateDirectory = "claude-board";
        LoadCredential = [
          "host-token:${secrets.claude-board-host-token.path}"
          "device-token:${secrets.claude-board-device-token.path}"
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
