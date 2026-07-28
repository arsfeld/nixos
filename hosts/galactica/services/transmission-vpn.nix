# Transmission — the download client behind the mydia pipeline on galactica.
#
# Confined to the PIA VPN namespace (constellation.pia) and listening on PIA's
# dynamically forwarded peer port. Unlike rqbit (which had no runtime port API
# and had to be restarted on every port change), Transmission exposes the peer
# port over RPC, so a port change is applied live via `transmission-remote -p`
# with no restart and no torrent interruption.
#
# Two paths feed the peer port, both through the same setPeerPort script:
#   - startup: ExecStartPost, reading constellation.pia's port file. Required
#     because the NixOS transmission module regenerates settings.json from the
#     declarative `settings` on *every* start, wiping any runtime port change.
#   - port change: constellation.pia's onPortChange hook, with the new port
#     in $PIA_FORWARDED_PORT.
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.transmission-vpn;
  vars = config.media.config;
  pia = config.constellation.pia;

  rpcPort = 9091;

  # Apply a peer port over Transmission's RPC. Takes the port as $1, falling
  # back to constellation.pia's port file when called without an argument.
  setPeerPort = pkgs.writeShellScript "transmission-set-peer-port" ''
    set -euo pipefail

    PORT="''${1:-}"
    if [ -z "$PORT" ]; then
      PORT=$(cat ${pia.portFile} 2>/dev/null || true)
    fi
    if [ -z "$PORT" ]; then
      echo "transmission: no PIA forwarded port available yet; leaving peer port as-is" >&2
      exit 0
    fi

    # ExecStartPost races transmission-daemon's RPC coming up, so poll rather
    # than assume it is already answering.
    for _ in $(seq 1 30); do
      if ${pkgs.transmission_4}/bin/transmission-remote 127.0.0.1:${toString rpcPort} -si >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    echo "transmission: setting peer port to $PORT" >&2
    exec ${pkgs.transmission_4}/bin/transmission-remote 127.0.0.1:${toString rpcPort} -p "$PORT"
  '';
in {
  options.services.transmission-vpn = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Transmission confined to the PIA VPN namespace";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Caddy proxies to the PIA namespace IP, not localhost: loopback traffic
    # bypasses the DNAT rules the namespace installs on PREROUTING.
    {
      media.services.transmission = {
        port = rpcPort;
        host = pia.namespaceAddress;
        bypassAuth = true;
      };
    }

    {
      # Stand up the PIA namespace and register Transmission as a consumer.
      # The hook only touches RPC, never systemd, so there is no restart cycle
      # to deadlock against pia-portforward (which dispatches this hook from
      # inside its own ExecStart).
      constellation.pia = {
        enable = true;
        consumers.transmission = {
          port = rpcPort;
          onPortChange = ''${setPeerPort} "$PIA_FORWARDED_PORT"'';
        };
      };

      services.transmission = {
        enable = true;
        package = pkgs.transmission_4;

        # Use Flood UI
        webHome = pkgs.flood-for-transmission;

        settings = {
          # Download directories
          download-dir = "${vars.storageDir}/media/Downloads";
          incomplete-dir-enabled = false; # Use .part extension instead of separate directory
          rename-partial-files = true; # Add .part extension to incomplete files
          watch-dir = "${vars.storageDir}/media/watch";
          watch-dir-enabled = true;

          # RPC/WebUI settings
          rpc-bind-address = "0.0.0.0";
          rpc-port = rpcPort;
          rpc-host-whitelist-enabled = false;
          rpc-whitelist-enabled = false;

          # Placeholder only. PIA assigns the peer port dynamically; the real
          # value is applied by setPeerPort at ExecStartPost and on every
          # onPortChange. Do not hardcode a provider port here.
          peer-port = 51413;
          peer-port-random-on-start = false;

          # Performance settings
          download-queue-enabled = true;
          download-queue-size = 10;
          seed-queue-enabled = true;
          seed-queue-size = 50;

          # Ratio and seed settings
          ratio-limit-enabled = false;
          idle-seeding-limit-enabled = false;

          # Misc settings
          umask = 2;
          encryption = 2; # Require encryption
        };

        # Set proper permissions for download directory
        downloadDirPermissions = "775";

        # Run as media user/group
        user = vars.user;
        group = vars.group;
      };

      systemd.services.transmission = {
        vpnConfinement = {
          enable = true;
          vpnNamespace = pia.namespace;
        };

        # Start only once a forwarded port is bound: pia-portforward stays
        # "active (exited)" after writing the port file, so this ordering is
        # what guarantees setPeerPort finds a port at ExecStartPost.
        after = ["pia-portforward.service"];
        requires = ["pia-portforward.service"];

        # Ensure directories exist before starting
        preStart = ''
          mkdir -p ${vars.storageDir}/media/Downloads
          mkdir -p ${vars.storageDir}/media/Downloads/radarr
          mkdir -p ${vars.storageDir}/media/Downloads/sonarr
          mkdir -p ${vars.storageDir}/media/watch
        '';

        serviceConfig = {
          # RootDirectoryStartOnly is set by the transmission module, so this
          # runs outside the chroot but still inside the PIA namespace, where
          # 127.0.0.1:9091 reaches the daemon.
          ExecStartPost = "${setPeerPort}";

          # Bind mount storage directories for access from VPN namespace
          BindPaths = [
            "${vars.storageDir}/media"
            "${vars.storageDir}/files"
          ];

          # Additional security hardening
          PrivateTmp = true;
          NoNewPrivileges = true;

          # Restart on failure
          Restart = lib.mkForce "on-failure";
          RestartSec = "5s";
        };
      };
    }
  ]);
}
