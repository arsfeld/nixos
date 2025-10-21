{
  self,
  lib,
  pkgs,
  config,
  ...
}: let
  harmoniaPort = 5000;
  healthcheckScript = pkgs.writeShellScript "harmonia-healthcheck" ''
    #!/usr/bin/env bash
    set -euo pipefail

    ${pkgs.curl}/bin/curl \
      --fail \
      --silent \
      --show-error \
      --max-time 10 \
      http://127.0.0.1:${toString harmoniaPort}/nix-cache-info \
      >/dev/null
  '';
in {
  age.secrets."harmonia-cache-key" = {
    file = "${self}/secrets/harmonia-cache-key.age";
    mode = "0400";
  };

  age.secrets."tailscale-key" = {
    file = "${self}/secrets/tailscale-key.age";
  };

  services.harmonia-dev = {
    cache = {
      enable = true;
      signKeyPaths = [config.age.secrets."harmonia-cache-key".path];
      settings = {
        bind = "[::]:${toString harmoniaPort}";
        enable_compression = true;
        priority = 60;
        virtual_nix_store = "/nix/store";
        real_nix_store = "/nix/store";
      };
    };
  };

  systemd.services.harmonia-dev = {
    after = lib.mkAfter ["network-online.target"];
    wants = ["network-online.target"];

    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = ["harmonia"];
    };
  };

  systemd.services.harmonia-healthcheck = {
    description = "Harmonia cache health probe";
    after = ["network-online.target" "harmonia-dev.service"];
    wants = ["network-online.target"];
    requires = ["harmonia-dev.service"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = healthcheckScript;
    };
  };

  systemd.timers.harmonia-healthcheck = {
    description = "Periodic Harmonia cache health probe";
    wantedBy = ["timers.target"];
    partOf = ["harmonia-healthcheck.service"];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "5m";
      RandomizedDelaySec = "1m";
    };
  };

  nix.settings = {
    keep-derivations = lib.mkDefault true;
    keep-outputs = lib.mkDefault true;
  };

  nix.gc.options = lib.mkForce "--max-free 75G --min-free 25G";

  # tsnsrv configuration for Tailscale node creation
  # The harmonia service is auto-configured via constellation.services
  # (see modules/constellation/services.nix and modules/media/gateway.nix)
  services.tsnsrv = {
    enable = true;
    prometheusAddr = "127.0.0.1:9099";
    defaults = {
      tags = ["tag:service"];
      authKeyPath = config.age.secrets."tailscale-key".path;
      ephemeral = true;
    };
  };
}
