# claude-board-voice: the speech side of the board's creature. Three loopback services the bridge
# (claude-board.nix) calls: whisper.cpp for speech to text, Piper for text to speech, and a Hermes
# agent for the replies. Nothing here listens beyond 127.0.0.1 and nothing opens a firewall port.
# Design: docs/superpowers/specs/2026-11-10-claude-board-creature-design.md
#
# The Hermes here is NOT the container in hermes.nix (disabled 2026-10-25 for a Brotli CVE in pages
# the agent browses). It is the NixOS module from the hermes-agent flake input, configured
# tool-less: `platform_toolsets` is empty for both the HTTP API and cron, so the agent can never
# browse a page, which removes that CVE's trigger, and can never run a command. Both lists matter:
# the same API key can create cron jobs, and those run with the cron toolsets, not the API's.
# After any bump of the input, check `GET /v1/toolsets` (bearer API key) still lists nothing enabled.
{
  configurations.nixos.galactica.module = {
    config,
    lib,
    pkgs,
    ...
  }: let
    sttPort = 18081;
    ttsPort = 18082;
    hermesPort = 18642;
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
    sops.secrets.hermes-api-key.restartUnits = ["claude-board.service" "hermes-agent.service"];
    # hermes-env is declared in hermes.nix; this unit takes only its DEEPSEEK_API_KEY.
    sops.secrets."hermes-env".restartUnits = ["hermes-agent.service"];

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
      settings = {
        model = {
          default = "deepseek-v4-flash";
          provider = "deepseek";
          base_url = "https://api.deepseek.com/v1";
        };
        # Tool-less: an explicit empty list is authoritative. Both are required (see the top).
        platform_toolsets = {
          api_server = [];
          cron = [];
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

    # The cron scheduler's user manager is not needed, and the creature has no cron toolset anyway.
    users.users.hermes.linger = lib.mkForce false;

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
    systemd.services.claude-board = {
      after = ["whisper-server.service" "piper-server.service" "hermes-agent.service"];
      wants = ["whisper-server.service" "piper-server.service" "hermes-agent.service"];
      environment = {
        BRIDGE_STT_URL = "http://127.0.0.1:${toString sttPort}";
        BRIDGE_TTS_URL = "http://127.0.0.1:${toString ttsPort}";
        BRIDGE_HERMES_URL = "http://127.0.0.1:${toString hermesPort}";
        BRIDGE_HERMES_KEY_FILE = "%d/hermes-key";
        BRIDGE_REPLY_TIMEOUT_SECS = "60";
      };
      serviceConfig.LoadCredential = ["hermes-key:${secrets.hermes-api-key.path}"];
    };
  };
}
