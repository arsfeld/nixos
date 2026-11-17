# Constellation PIA module
#
# Runs Private Internet Access (PIA) in its own VPN-Confinement WireGuard
# namespace and performs PIA's dynamic, API-driven port forwarding. Exposes an
# extensible consumer seam so any app can attach: declare a consumer, get the
# forwarded port handed to it via $PIA_FORWARDED_PORT, and react to changes.
#
# The control plane is the Rust binary in packages/pia (`pia connect|portforward|watchdog`);
# this module wires it into units and passes its settings as PIA_* environment variables.
#
# Architecture (see docs/plans/2026-05-30-001-feat-pia-vpn-port-forwarding-plan.md):
#   pia-connect.service (host netns, oneshot)
#     token + /addKey  ->  /run/pia/wg0.conf  +  /var/lib/pia/state.json
#   <ns>-up.service (VPN-Confinement) brings up the tunnel from that config
#   pia-portforward.service (inside <ns>) getSignature/bindPort, persists port,
#     opens the dynamic port on the tunnel interface, dispatches consumer hooks
#   pia-portforward-refresh.timer re-binds every 14 minutes (PIA keepalive)
#   pia-watchdog.timer restarts <ns> when the WireGuard handshake goes stale
#
# PIA port forwarding is dynamic: PIA assigns the port (payload valid ~60 days),
# and the binding must be refreshed every <=15 minutes. The port is cached so it
# survives reboots and rebinds without requesting a new signature.
{
  configurations.nixos.galactica.module = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.constellation.pia;
    ns = cfg.namespace;

    caCert = ./pia-ca.rsa.4096.crt;
    mkPiaTunnel = import ./_pia/tunnel.nix {inherit lib pkgs;};

    portFilePath = "/run/pia/forwarded-port"; # world-readable bare port for consumers

    # Consumer port-change hook: runs every consumer's onPortChange with the
    # forwarded port in $PIA_FORWARDED_PORT. This is the extensibility seam.
    hookScript = pkgs.writeShellScript "pia-pf-hook" ''
      set -euo pipefail
      PORT="''${1:?usage: pia-pf-hook <port>}"
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: c: ''
          echo "pia: notifying consumer '${name}' of forwarded port $PORT" >&2
          (
            export PIA_FORWARDED_PORT="$PORT"
            ${c.onPortChange}
          )
        '')
        cfg.consumers)}
    '';

    # Settings for every `pia` subcommand. Tools are passed by absolute path.
    piaEnv = {
      PIA_CREDENTIALS = toString cfg.credentialsFile;
      PIA_REGION = cfg.region;
      PIA_CA_CERT = "${caCert}";
      PIA_NAMESPACE = ns;
      PIA_HOOK = "${hookScript}";
      PIA_WG = "${pkgs.wireguard-tools}/bin/wg";
      PIA_IP = "${pkgs.iproute2}/bin/ip";
      PIA_IPTABLES = "${pkgs.iptables}/bin/iptables";
      PIA_SYSTEMCTL = "${pkgs.systemd}/bin/systemctl";
    };
    pia = lib.getExe pkgs.pia;

    # Web-UI port mappings derived from declared consumers.
    consumerPortMappings =
      lib.mapAttrsToList (_: c: {
        from = c.port;
        to = c.port;
        protocol = "tcp";
      })
      (lib.filterAttrs (_: c: c.port != null) cfg.consumers);
  in {
    options.constellation.pia = {
      credentialsFile = lib.mkOption {
        type = lib.types.path;
        default = config.sops.secrets."pia-credentials".path;
        defaultText = lib.literalExpression ''config.sops.secrets."pia-credentials".path'';
        description = ''
          Path to an env file exporting PIA_USER and PIA_PASS for the PIA account.
        '';
      };

      region = lib.mkOption {
        type = lib.types.str;
        default = "auto";
        example = "ca_toronto";
        description = ''
          PIA region id to connect to, or "auto" for the first port-forward-capable
          region. US regions do not support port forwarding.
        '';
      };

      namespace = lib.mkOption {
        type = lib.types.str;
        default = "pia";
        description = "Name of the VPN-Confinement network namespace.";
      };

      namespaceAddress = lib.mkOption {
        type = lib.types.str;
        default = "192.168.16.1";
        description = ''
          Service-side namespace address (where the gateway proxies). Must not
          collide with the AirVPN namespace subnet (192.168.15.0/24).
        '';
      };

      bridgeAddress = lib.mkOption {
        type = lib.types.str;
        default = "192.168.16.5";
        description = "Host-side bridge address for the namespace veth pair.";
      };

      portFile = lib.mkOption {
        type = lib.types.path;
        default = portFilePath;
        readOnly = true;
        description = "World-readable file holding the current forwarded port as a bare integer.";
      };

      consumers = lib.mkOption {
        default = {};
        description = ''
          Apps attached to the PIA namespace. Each consumer's onPortChange runs
          with the forwarded port in $PIA_FORWARDED_PORT whenever it changes.
        '';
        example = lib.literalExpression ''
          {
            transmission = {
              port = 9091;
              onPortChange = "transmission-remote 127.0.0.1:9091 -p \"$PIA_FORWARDED_PORT\"";
            };
          }
        '';
        type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
          options = {
            onPortChange = lib.mkOption {
              type = lib.types.lines;
              description = "Shell run (with $PIA_FORWARDED_PORT set) when the port changes.";
            };
            port = lib.mkOption {
              type = lib.types.nullOr lib.types.port;
              default = null;
              description = "Web-UI port to map from host into the namespace (null = none).";
            };
            host = lib.mkOption {
              type = lib.types.str;
              default = cfg.namespaceAddress;
              description = "Namespace IP the gateway should proxy this consumer's web UI to.";
            };
          };
        }));
      };
    };

    config = lib.mkMerge [
      {
        sops.secrets."pia-credentials" = lib.mkDefault {mode = "0400";};
      }

      # PIA WireGuard namespace, alongside the AirVPN "wg" namespace.
      (mkPiaTunnel {
        namespace = ns;
        connectUnit = "pia-connect";
        watchdogUnit = "pia-watchdog";
        inherit (cfg) namespaceAddress bridgeAddress;
        env = piaEnv;
        allowedIngress = [
          "100.64.0.0/10" # Tailscale CGNAT
          "10.0.0.0/8" # Local networks (incl. Podman)
          "192.168.0.0/16"
        ];
        portMappings = consumerPortMappings;
      })

      {
        systemd.services.pia-portforward = {
          description = "PIA: acquire and bind the forwarded port";
          environment = piaEnv;
          after = ["${ns}.service"];
          requires = ["${ns}.service"];
          wantedBy = ["${ns}.service"];
          # No start-rate limiter: a transient getSignature failure should be freely
          # retriable by the timer and by re-activation.
          startLimitIntervalSec = 0;
          vpnConfinement = {
            enable = true;
            vpnNamespace = ns;
          };
          serviceConfig = {
            Type = "oneshot";
            # Stay "active (exited)" so consumers can hard-require a bound port.
            RemainAfterExit = true;
            ExecStart = "${pia} portforward";
            StateDirectory = "pia";
          };
        };

        # The keepalive runs as its own unit. A timer cannot re-run pia-portforward:
        # starting a RemainAfterExit unit that is already active is a no-op, so the
        # timer fired once after boot, never again (NextElapse=infinity), and the
        # binding lapsed 15 minutes after every start.
        systemd.services.pia-portforward-refresh = {
          description = "PIA: re-bind the forwarded port (keepalive)";
          environment = piaEnv;
          after = ["${ns}.service" "pia-portforward.service"];
          # Never bring the tunnel up from here; that is pia-watchdog's job.
          requisite = ["${ns}.service"];
          vpnConfinement = {
            enable = true;
            vpnNamespace = ns;
          };
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pia} portforward";
            StateDirectory = "pia";
          };
        };

        systemd.timers.pia-portforward-refresh = {
          description = "PIA: re-bind the forwarded port (15-min keepalive)";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "15min";
            OnUnitActiveSec = "14min";
          };
        };
      }
    ];
  };
}
