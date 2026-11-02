# Keeps tuya_local pointed at each device's current IP; rehost.py says how.
# Design: docs/superpowers/specs/2026-11-01-ir-hub-rehost-design.md
#
# `journalctl -u tuya-local-rehost` shows each check that failed and every
# rewrite; the old config is kept beside it as core.config_entries.bak-<UTC>.
{
  configurations.nixos.galactica.module = {pkgs, ...}: let
    rehost = pkgs.writers.writePython3Bin "tuya-local-rehost" {
      libraries = [pkgs.python3Packages.tinytuya];
      flakeIgnore = ["E501"];
    } (builtins.readFile ./rehost.py);
  in {
    systemd.services.tuya-local-rehost = {
      description = "Point tuya_local entries at their device's current IP";
      after = ["home-assistant.service"];
      path = [pkgs.systemd];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${rehost}/bin/tuya-local-rehost";
        StateDirectory = "tuya-local-rehost";
      };
    };
    systemd.timers.tuya-local-rehost = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "5min";
      };
    };
  };
}
