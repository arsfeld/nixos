# cylon-bot-voice: the speech side of the board's creature. Three loopback services the bridge
# (cylon-bot.nix) calls: whisper.cpp for speech to text, Piper for text to speech, and a Hermes
# agent for the replies. Nothing here listens beyond 127.0.0.1 and nothing opens a firewall port.
# Design: docs/superpowers/specs/2026-11-10-cylon-bot-creature-design.md
#
# The Hermes here is NOT the container in hermes.nix (disabled 2026-10-25). It is the NixOS module
# from the hermes-agent flake input, with Hermes' core tools: `platform_toolsets` names the stock
# bundles for the HTTP API and for cron. Both are set, because the same API key can create cron
# jobs and those run with the cron toolsets, not the API's. They are written explicitly rather than
# left out because the module deep-merges `settings` into an existing config.yaml, so a key left
# out keeps whatever value is already on disk.
#
# Besides its core tools, Hermes reaches one MCP server, the bridge's (`mcp_servers.cylon-bot`,
# http://127.0.0.1:8591/mcp, token-gated). It has the timer tools and, with BRIDGE_HA_URL and
# BRIDGE_HA_TOKEN_FILE set below, `weather_forecast` (the bridge reads Home Assistant's daily forecast
# itself) and Home Assistant's own Assist tools, which the bridge proxies from HA's MCP server
# (http://127.0.0.1:8123/api/mcp, the mcp_server integration in home-assistant.nix) as the non-admin
# `creature` user whose token is hermes-creature-ha-token, minus `HassCancelAllTimers` (it acts on
# HA's timers, not the board's). Hermes reaches HA only through the bridge, and the HA token lives
# only in the bridge's DynamicUser credentials, because Hermes has a terminal: holding the token, a
# prompt injection could curl HA's REST API and call any service (HA has no per-entity permissions;
# Assist exposure limits only the Assist and MCP APIs). Hermes adds each MCP server as toolset
# `mcp-<name>` next to the platform bundles on its own, so `platform_toolsets` must NOT name one:
# that would turn the list into an allowlist. After any bump of the hermes-agent input, check that
# `GET /v1/toolsets` still lists the MCP toolset (and nothing else enabled that should not be). A
# server that is down at start is retried and re-probed every 300 s, so there is no unit ordering
# between hermes-agent and cylon-bot.
{
  configurations.nixos.galactica.module = {
    config,
    lib,
    options,
    pkgs,
    ...
  }: let
    sttPort = 18081;
    ttsPort = 18082;
    hermesPort = 18642;
    mcpPort = 8591;
    stateDir = "/var/lib/hermes-creature";
    secrets = config.sops.secrets;

    # Both binaries come from nixpkgs-unstable: the measured versions (whisper-cpp 1.9.5, piper-tts 1.8.0).
    # Stable's piper-tts 1.4.2 serves POST / and not /synthesize, which the bridge calls.
    # No packaged ggml model or Piper voice exists in nixpkgs; the hashes make an upstream change
    # fail the build rather than slip through.
    whisperModel = pkgs.fetchurl {
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";
      hash = "sha256-oDd5yG3zMjB19eeWyyzlAp8A7Ihp7uP9+4l6/jbG0AI=";
    };
    # The .onnx and its .onnx.json must sit side by side under one stem.
    piperVoice = pkgs.linkFarm "piper-voice-en_US-lessac-medium" [
      {
        name = "en_US-lessac-medium.onnx";
        path = pkgs.fetchurl {
          url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx?download=true";
          name = "en_US-lessac-medium.onnx";
          hash = "sha256-Xv4J5pkCGHgnr2RuGm6dJp3udp+Yd9F7FrG0buqvAZ8=";
        };
      }
      {
        name = "en_US-lessac-medium.onnx.json";
        path = pkgs.fetchurl {
          url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json?download=true";
          name = "en_US-lessac-medium.onnx.json";
          hash = "sha256-7+GcQXvtBV8taZCCSMa6ZQ+hNbyGiw5quz2hgdq2kKA=";
        };
      }
    ];
    # nixpkgs' piper-tts ships the Flask server (piper/http_server.py) but no executable for it.
    # The wrapper sets sys.path for the Nix closure, so reuse it with a different entry point.
    piperHttp = pkgs.runCommand "piper-http" {} ''
      mkdir -p $out/bin
      sed 's/piper.__main__ import main/piper.http_server import main/' \
        ${pkgs.unstable.piper-tts}/bin/.piper-wrapped > $out/bin/piper-http
      # A piper-tts bump that moves the entry point must fail the build, not the deploy.
      grep -q 'piper.http_server import main' $out/bin/piper-http || {
        echo "piper-http: the rewrite of .piper-wrapped did not apply; piper-tts changed its entry point" >&2
        exit 1
      }
      chmod +x $out/bin/piper-http
    '';

    # Hardening shared by the two speech services (dynamic users, no home, no writes).
    hardening = {
      DynamicUser = true;
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
      SystemCallArchitectures = "native";
    };
    # Low priority and bounded memory, so a burst of voice work cannot starve the media stack on
    # this box. No CPUQuota: it would only add latency while the machine is idle.
    lowPriority = {
      Nice = 10;
      CPUWeight = 20;
      IOWeight = 20;
    };
  in {
    # Read by the bridge (LoadCredential) and by Hermes (as API_SERVER_KEY).
    sops.secrets.hermes-api-key.restartUnits = ["cylon-bot.service" "hermes-agent.service"];
    # The bridge's MCP bearer token: the bridge checks it, Hermes sends it (as CYLON_BOT_MCP_TOKEN).
    sops.secrets.cylon-bot-mcp-token.restartUnits = ["cylon-bot.service" "hermes-agent.service"];
    # hermes-env is declared in hermes.nix; this unit takes only its DEEPSEEK_API_KEY.
    sops.secrets."hermes-env".restartUnits = ["hermes-agent.service"];
    # A long-lived token of Home Assistant's non-admin `creature` user. Only the bridge reads it: for
    # the forecast (REST) and for the HA tools it proxies (MCP). Never give it to hermes-agent.
    sops.secrets.hermes-creature-ha-token.restartUnits = ["cylon-bot.service"];

    systemd.services.whisper-server = {
      description = "whisper.cpp speech to text for the board's creature";
      wantedBy = ["multi-user.target"];
      serviceConfig =
        hardening
        // lowPriority
        // {
          MemoryMax = "2G";
          # 8 threads measured 0.6 s for a 5 s utterance with base.en on this box.
          ExecStart = lib.escapeShellArgs [
            "${pkgs.unstable.whisper-cpp}/bin/whisper-server"
            "-m"
            "${whisperModel}"
            "-t"
            "8"
            "-l"
            "en"
            "--host"
            "127.0.0.1"
            "--port"
            (toString sttPort)
          ];
        };
    };

    systemd.services.piper-server = {
      description = "Piper text to speech for the board's creature";
      wantedBy = ["multi-user.target"];
      serviceConfig =
        hardening
        // lowPriority
        // {
          MemoryMax = "1G";
          RestrictAddressFamilies = ["AF_INET"];
          # Always bind loopback: the server's own default is 0.0.0.0.
          ExecStart = lib.escapeShellArgs [
            "${piperHttp}/bin/piper-http"
            "--host"
            "127.0.0.1"
            "--port"
            (toString ttsPort)
            "-m"
            "${piperVoice}/en_US-lessac-medium.onnx"
          ];
        };
    };

    services.hermes-agent = {
      enable = true;
      inherit stateDir;
      # Hermes builds against its own nixpkgs pin, whose curl links brotli 1.2.0 (CVE-2026-111497),
      # and puts that git (and its curl) on the agent's PATH. Swap in ours. Following our
      # nixpkgs-unstable instead is not an option: Hermes patches patchelf for 0.19.2 and
      # unstable's is 0.15.2. Delete once `just cve-2026-111497-check galactica` passes without it.
      package = options.services.hermes-agent.package.default.override {inherit (pkgs) git;};
      settings = {
        model = {
          default = "deepseek-v4-flash";
          provider = "deepseek";
          base_url = "https://api.deepseek.com/v1";
        };
        # The core tools (toolsets.py `_HERMES_CORE_TOOLS`): the API bundle drops only the
        # interactive ones (clarify, text_to_speech, computer_use). Default-off toolsets stay off.
        platform_toolsets = {
          api_server = ["hermes-api-server"];
          cron = ["hermes-cron"];
        };
        # Tool search hides every MCP tool behind a search round trip (measured: the creature used
        # curl for weather and needed 6 model calls for a house question). Off sends every tool each
        # turn, about 5,900 more prompt tokens, which DeepSeek's prompt cache absorbs (~98% hit rate
        # measured). The module deep-merges settings into config.yaml, so an explicit value is required.
        tools.tool_search.enabled = "off";
        # The bridge's tools, Home Assistant's included. Hermes interpolates `${VAR}` from its own
        # environment at start (and fails closed if it is unset), so config.yaml carries the
        # placeholder, never the token.
        mcp_servers.cylon-bot = {
          url = "http://127.0.0.1:${toString mcpPort}/mcp";
          headers.Authorization = "Bearer \${CYLON_BOT_MCP_TOKEN}";
        };
        # Hermes used to reach HA's MCP server directly. The merge into config.yaml cannot delete a
        # key, so the old entry stays on disk; this switches it off. Remove this once galactica's
        # /var/lib/hermes-creature config.yaml no longer has a `homeassistant` server.
        mcp_servers.homeassistant.enabled = false;
        # The same for the bridge's server under its pre-rename name. Its stale header still holds
        # a `${CLAUDE_BOARD_MCP_TOKEN}` placeholder that nothing sets any more, and Hermes fails
        # closed on an unset variable, so the header is overwritten too. Remove this with the
        # entry above, once `claude-board` is gone from that config.yaml.
        mcp_servers.claude-board = {
          enabled = false;
          headers.Authorization = "";
        };
      };
      # Not secret. The key and the DeepSeek key come from the unit's EnvironmentFile below.
      environment = {
        API_SERVER_ENABLED = "true";
        API_SERVER_HOST = "127.0.0.1";
        API_SERVER_PORT = toString hermesPort;
      };
      hermesHomeFiles."SOUL.md" = ./_creature/SOUL.md;
    };

    systemd.services.hermes-agent = {
      serviceConfig =
        lowPriority
        // {
          MemoryMax = "2G";
          # hermes-env also holds the old gateway's Telegram and dashboard variables, and a Telegram
          # token would switch on a chat platform with its default toolsets. So the unit gets only the
          # one line it needs from it, plus the API key, in a file only this service can read.
          LoadCredential = [
            "hermes-env:${secrets."hermes-env".path}"
            "api-key:${secrets.hermes-api-key.path}"
            "mcp-token:${secrets.cylon-bot-mcp-token.path}"
          ];
          RuntimeDirectory = "hermes-creature";
          RuntimeDirectoryMode = "0700";
          # systemd reads EnvironmentFile just before each command, so ExecStartPre can write it.
          EnvironmentFile = "-%t/hermes-creature/env";
          ExecStartPre = [
            (pkgs.writeShellScript "hermes-creature-env" ''
              set -eu
              umask 077
              {
                ${pkgs.gnugrep}/bin/grep -E '^DEEPSEEK_API_KEY=' "$CREDENTIALS_DIRECTORY/hermes-env"
                printf 'API_SERVER_KEY=%s\n' "$(${pkgs.coreutils}/bin/tr -d '\n' < "$CREDENTIALS_DIRECTORY/api-key")"
                printf 'CYLON_BOT_MCP_TOKEN=%s\n' "$(${pkgs.coreutils}/bin/tr -d '\n' < "$CREDENTIALS_DIRECTORY/mcp-token")"
              } > "$RUNTIME_DIRECTORY/env"
            '')
          ];
          ProtectHome = lib.mkForce true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
          RestrictNamespaces = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
        };
    };

    # The bridge starts and serves approvals whether or not a backend is up: ordered after, never
    # required by, the voice services.
    systemd.services.cylon-bot = {
      after = ["whisper-server.service" "piper-server.service" "hermes-agent.service"];
      wants = ["whisper-server.service" "piper-server.service" "hermes-agent.service"];
      environment = {
        BRIDGE_STT_URL = "http://127.0.0.1:${toString sttPort}";
        BRIDGE_TTS_URL = "http://127.0.0.1:${toString ttsPort}";
        BRIDGE_HERMES_URL = "http://127.0.0.1:${toString hermesPort}";
        BRIDGE_HERMES_KEY_FILE = "%d/hermes-key";
        BRIDGE_REPLY_TIMEOUT_SECS = "60";
        # The timer tools' MCP endpoint, for Hermes only (loopback; timers persist in
        # $STATE_DIRECTORY/timers.json, see cylon-bot.nix).
        BRIDGE_MCP_LISTEN = "127.0.0.1:${toString mcpPort}";
        BRIDGE_MCP_TOKEN_FILE = "%d/mcp-token";
        # Home Assistant: the weather_forecast tool (entity defaults to weather.forecast_home) and
        # HA's own MCP tools, proxied. The token is the bridge's alone.
        BRIDGE_HA_URL = "http://127.0.0.1:8123";
        BRIDGE_HA_TOKEN_FILE = "%d/ha-token";
      };
      serviceConfig.LoadCredential = [
        "hermes-key:${secrets.hermes-api-key.path}"
        "mcp-token:${secrets.cylon-bot-mcp-token.path}"
        "ha-token:${secrets.hermes-creature-ha-token.path}"
      ];
    };
  };
}
