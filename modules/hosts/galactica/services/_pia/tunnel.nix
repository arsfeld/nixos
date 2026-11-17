# One PIA WireGuard tunnel: its VPN-Confinement namespace, the oneshot that
# registers a key and writes the WireGuard config, and the watchdog that restarts
# the namespace when the handshake goes stale. Used for Transmission's `pia`
# namespace (pia.nix) and for each exit slot.
#
# `env` is the complete PIA_* environment for the `pia` binary; the helper reads
# PIA_RUN_DIR and PIA_STATE_DIR from it (falling back to the binary's defaults,
# /run/pia and /var/lib/pia) but never adds variables of its own.
#
# With `target` set, the tunnel belongs to that target: the namespace is wanted
# by it instead of multi-user.target, every unit is partOf it, and the watchdog
# timer runs only while it is active.
#
# Usage: mkPiaTunnel = import ./_pia/tunnel.nix {inherit lib pkgs;};
{
  lib,
  pkgs,
}: {
  namespace,
  connectUnit,
  watchdogUnit,
  namespaceAddress,
  bridgeAddress,
  env,
  allowedIngress ? [],
  portMappings ? [],
  target ? null,
}: let
  pia = lib.getExe pkgs.pia;
  nsUnit = "${namespace}.service";
  runDir = env.PIA_RUN_DIR or "/run/pia";
  stateDirectory =
    if env ? PIA_STATE_DIR
    then baseNameOf env.PIA_STATE_DIR
    else "pia";
  targetPartOf = lib.optional (target != null) target;
in {
  vpnNamespaces.${namespace} = {
    enable = true;
    wireguardConfigFile = "${runDir}/wg0.conf"; # root-only: WireGuard private key
    inherit namespaceAddress bridgeAddress allowedIngress portMappings;
    # The forwarded peer port is dynamic and opened at runtime by the PF daemon
    # (openVPNPorts is build-time only, so it can't carry the assigned port).
    openVPNPorts = [];
  };

  systemd.services =
    {
      ${connectUnit} = {
        description = "PIA: authenticate and generate WireGuard tunnel config";
        environment = env;
        after = ["network-online.target" "nss-lookup.target"];
        wants = ["network-online.target" "nss-lookup.target"];
        before = [nsUnit];
        requiredBy = [nsUnit];
        # Restarting the tunnel (a deploy, a manual restart) must re-run connect.
        # Otherwise this RemainAfterExit oneshot stays "active" and the tunnel comes
        # back up against the server cached in wg0.conf, which PIA may have retired
        # since: pia-up then dies with "failed to reach '<ip>' after 5 attempts".
        partOf = [nsUnit] ++ targetPartOf;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pia} connect";
          StateDirectory = stateDirectory;
        };
      };

      # Nothing else notices a dead tunnel: every unit stays "active" while the
      # namespace has no route out. On 2026-11-09 the server stopped answering and
      # Transmission sat idle for 2.5 days. With PersistentKeepalive = 25 a live
      # peer re-handshakes every 2 minutes, so a handshake older than 5 minutes
      # means the server is gone; restarting the namespace re-runs the connect
      # unit, which registers a fresh key on a server picked from the current list.
      ${watchdogUnit} = {
        description = "PIA: restart the tunnel when its handshake goes stale";
        environment = env;
        after = [nsUnit];
        partOf = targetPartOf;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pia} watchdog";
        };
      };
    }
    // lib.optionalAttrs (target != null) {
      # VPN-Confinement makes every namespace wantedBy multi-user.target.
      ${namespace} = {
        wantedBy = lib.mkForce [target];
        partOf = [target];
      };
    };

  systemd.timers.${watchdogUnit} = {
    description = "PIA: check the tunnel handshake every 2 minutes";
    wantedBy =
      if target != null
      then [target]
      else ["timers.target"];
    partOf = targetPartOf;
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "2min";
    };
  };
}
