# rqbit — fast BitTorrent client (https://github.com/ikatson/rqbit)
#
# First consumer of the PIA VPN namespace (constellation.pia). Confined to the
# PIA tunnel, web UI fronted by Authelia at rqbit.arsfeld.one, listening on the
# PIA-forwarded peer port. rqbit has no runtime port API (v8.1.1), so it consumes
# the forwarded port by reading it at start and restarting when it changes.
#
# Standalone try-out client: NOT wired into the Sonarr/Radarr pipeline.
{
  config,
  self,
  pkgs,
  lib,
  ...
}: let
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  cfg = config.services.rqbit-vpn;
  vars = config.media.config;
  pia = config.constellation.pia;

  webPort = 3030;
  downloadDir = "${vars.storageDir}/media/Downloads/rqbit";

  # Read the PIA-forwarded port at exec time and launch rqbit on it. A wrapper
  # (not EnvironmentFile) because systemd reads EnvironmentFile once at unit
  # activation, before any port file would be refreshed.
  rqbitStart = pkgs.writeShellScript "rqbit-start" ''
    set -euo pipefail
    P=$(cat ${pia.portFile} 2>/dev/null || true)
    if [ -z "$P" ]; then
      echo "rqbit: no PIA forwarded port available yet (is pia-portforward up?)" >&2
      exit 1
    fi
    exec ${pkgs.rqbit}/bin/rqbit \
      --http-api-listen-addr 0.0.0.0:${toString webPort} \
      --tcp-min-port "$P" \
      --tcp-max-port "$P" \
      --disable-upnp-port-forward \
      --persistence-location /var/lib/rqbit \
      server start ${downloadDir}
  '';
in {
  options.services.rqbit-vpn = {
    enable = lib.mkEnableOption "rqbit BitTorrent client confined to the PIA VPN namespace";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Caddy proxies to the PIA namespace IP. No bypassAuth: rqbit has no built-in
    # auth, so the public hostname sits behind Authelia.
    (mkService "rqbit" {
      port = webPort;
      host = pia.namespaceAddress;
    })

    {
      # Stand up the PIA namespace and register rqbit as a consumer. rqbit has no
      # runtime port API, so a port change triggers a restart.
      constellation.pia = {
        enable = true;
        consumers.rqbit = {
          port = webPort;
          onPortChange = "systemctl restart rqbit";
        };
      };

      systemd.services.rqbit = {
        description = "rqbit BitTorrent client confined to PIA VPN";
        wantedBy = ["multi-user.target"];
        after = ["pia-portforward.service"];
        wants = ["pia-portforward.service"];

        vpnConfinement = {
          enable = true;
          vpnNamespace = pia.namespace;
        };

        preStart = ''
          mkdir -p ${downloadDir}
        '';

        serviceConfig = {
          Type = "simple";
          User = vars.user;
          Group = vars.group;

          ExecStart = "${rqbitStart}";

          Restart = "on-failure";
          RestartSec = "10s";

          # Make storage available inside the namespace.
          BindPaths = [
            "${vars.storageDir}/media"
            "${vars.storageDir}/files"
          ];

          StateDirectory = "rqbit";
          StateDirectoryMode = "0750";
          PrivateTmp = true;
          NoNewPrivileges = true;
        };

        environment = {
          HOME = "/var/lib/rqbit";
        };
      };
    }
  ]);
}
