# Constellation PIA module
#
# Runs Private Internet Access (PIA) in its own VPN-Confinement WireGuard
# namespace and performs PIA's dynamic, API-driven port forwarding. Exposes an
# extensible consumer seam so any app can attach: declare a consumer, get the
# forwarded port handed to it via $PIA_FORWARDED_PORT, and react to changes.
#
# Architecture (see docs/plans/2026-05-30-001-feat-pia-vpn-port-forwarding-plan.md):
#   pia-connect.service (host netns, oneshot)
#     token + /addKey  ->  /run/pia/wg0.conf  +  /var/lib/pia/state.json
#   <ns>-up.service (VPN-Confinement) brings up the tunnel from that config
#   pia-portforward.service (inside <ns>) getSignature/bindPort, persists port,
#     opens the dynamic port on the tunnel interface, dispatches consumer hooks
#   pia-portforward.timer re-binds every 15 minutes (PIA keepalive)
#
# PIA port forwarding is dynamic: PIA assigns the port (payload valid ~60 days),
# and the binding must be refreshed every <=15 minutes. The port is cached so it
# survives reboots and rebinds without requesting a new signature.
#
# NOTE: This module is build-verified. The PIA API flow (ported from
# pia-foss/manual-connections) requires valid PIA credentials and a galactica
# deploy to verify at runtime.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.pia;
  ns = cfg.namespace;

  caCert = ./pia-ca.rsa.4096.crt;

  statePath = "/var/lib/pia/state.json"; # root-only: token, payload, signature
  wgConfPath = "/run/pia/wg0.conf"; # root-only: WireGuard private key
  portFilePath = "/run/pia/forwarded-port"; # world-readable bare port for consumers

  # Consumer port-change hook: runs every consumer's onPortChange with the
  # forwarded port in $PIA_FORWARDED_PORT. This is the extensibility seam.
  hookScript = pkgs.writeShellScript "pia-pf-hook" ''
    set -euo pipefail
    PORT="''${1:?usage: pia-pf-hook <port>}"
    ${concatStringsSep "\n" (mapAttrsToList (name: c: ''
        echo "pia: notifying consumer '${name}' of forwarded port $PORT" >&2
        (
          export PIA_FORWARDED_PORT="$PORT"
          ${c.onPortChange}
        )
      '')
      cfg.consumers)}
  '';

  # U3: authenticate to PIA, register an ephemeral WireGuard key, and write the
  # tunnel config + state cache. Runs in the host netns before the tunnel is up.
  connectScript = pkgs.writeShellApplication {
    name = "pia-connect";
    runtimeInputs = with pkgs; [curl jq wireguard-tools coreutils gnugrep];
    text = ''
      set -euo pipefail

      # shellcheck source=/dev/null
      source "${cfg.credentialsFile}"
      : "''${PIA_USER:?missing PIA_USER in credentials file}"
      : "''${PIA_PASS:?missing PIA_PASS in credentials file}"

      # /run/pia is traversable so consumers can read the bare port file;
      # wg0.conf inside it stays 0600 (holds the private key).
      install -d -m 0755 /run/pia
      install -d -m 0700 /var/lib/pia

      echo "pia: requesting auth token" >&2
      token=$(curl -fsSL --location --request POST \
        'https://www.privateinternetaccess.com/api/client/v2/token' \
        --form "username=$PIA_USER" --form "password=$PIA_PASS" | jq -r '.token')
      [ -n "$token" ] && [ "$token" != "null" ] || { echo "pia: token request failed" >&2; exit 1; }

      echo "pia: fetching server list" >&2
      # The v6 server list prepends a signature line; the first line is the JSON body.
      servers=$(curl -fsSL "https://serverlist.piaservers.net/vpninfo/servers/v6" | head -1)

      region="${cfg.region}"
      if [ "$region" = "auto" ]; then
        # First port-forward-capable region.
        sel=$(echo "$servers" | jq -c 'first(.regions[] | select(.port_forward == true))')
      else
        sel=$(echo "$servers" | jq -c --arg id "$region" \
          'first(.regions[] | select(.id == $id))')
      fi
      [ -n "$sel" ] && [ "$sel" != "null" ] || { echo "pia: no matching region for '$region'" >&2; exit 1; }
      if [ "$(echo "$sel" | jq -r '.port_forward')" != "true" ]; then
        echo "pia: region '$region' does not support port forwarding (US regions never do)" >&2
        exit 1
      fi

      wg_ip=$(echo "$sel" | jq -r '.servers.wg[0].ip')
      wg_cn=$(echo "$sel" | jq -r '.servers.wg[0].cn')
      echo "pia: selected region '$(echo "$sel" | jq -r '.id')' server $wg_cn ($wg_ip)" >&2

      priv=$(wg genkey)
      pub=$(echo "$priv" | wg pubkey)

      echo "pia: registering key with $wg_cn" >&2
      addkey=$(curl -fsSL -G \
        --connect-to "$wg_cn::$wg_ip:" \
        --cacert "${caCert}" \
        --data-urlencode "pt=$token" \
        --data-urlencode "pubkey=$pub" \
        "https://$wg_cn:1337/addKey")
      [ "$(echo "$addkey" | jq -r '.status')" = "OK" ] || { echo "pia: addKey failed: $addkey" >&2; exit 1; }

      server_key=$(echo "$addkey" | jq -r '.server_key')
      server_port=$(echo "$addkey" | jq -r '.server_port')
      server_ip=$(echo "$addkey" | jq -r '.server_ip')
      server_vip=$(echo "$addkey" | jq -r '.server_vip')
      peer_ip=$(echo "$addkey" | jq -r '.peer_ip')
      dns=$(echo "$addkey" | jq -r '.dns_servers[0]')

      umask 077
      cat > "${wgConfPath}" <<EOF
      [Interface]
      Address = $peer_ip
      PrivateKey = $priv
      DNS = $dns

      [Peer]
      PersistentKeepalive = 25
      PublicKey = $server_key
      AllowedIPs = 0.0.0.0/0
      Endpoint = $server_ip:$server_port
      EOF

      # Persist what the PF daemon needs. Preserve any existing payload/port so a
      # reconnect with the same account can keep rebinding the same port until
      # expiry. (The payload is tied to the token, not the tunnel.)
      tmp=$(mktemp)
      prev='{}'
      [ -f "${statePath}" ] && prev=$(cat "${statePath}")
      echo "$prev" | jq \
        --arg token "$token" \
        --arg gateway "$server_vip" \
        --arg hostname "$wg_cn" \
        '. + {token: $token, pf_gateway: $gateway, pf_hostname: $hostname}' > "$tmp"
      install -m 0600 "$tmp" "${statePath}"
      rm -f "$tmp"
      echo "pia: tunnel config written; gateway $server_vip" >&2
    '';
  };

  # U4: acquire/refresh the port-forward signature, bind it (15-min keepalive),
  # open the dynamic port on the tunnel interface, and dispatch consumer hooks on
  # change. Runs INSIDE the namespace (the PF gateway is only reachable over the
  # tunnel).
  portforwardScript = pkgs.writeShellApplication {
    name = "pia-portforward";
    runtimeInputs = with pkgs; [curl jq coreutils iptables iproute2];
    text = ''
      set -euo pipefail

      [ -f "${statePath}" ] || { echo "pia-pf: no state yet (connect not run)" >&2; exit 1; }
      state=$(cat "${statePath}")
      token=$(echo "$state" | jq -r '.token')
      gateway=$(echo "$state" | jq -r '.pf_gateway')
      hostname=$(echo "$state" | jq -r '.pf_hostname')
      payload=$(echo "$state" | jq -r '.payload // empty')
      signature=$(echo "$state" | jq -r '.signature // empty')
      expires=$(echo "$state" | jq -r '.expires_at // empty')
      applied=$(echo "$state" | jq -r '.applied_port // empty')

      # The namespace's accessibleFrom 10.0.0.0/8 route (to the host bridge) would
      # otherwise capture the PF gateway VIP (also in 10/8) and send getSignature
      # back out the veth instead of through the tunnel. Pin a /32 host route via
      # the tunnel so the more-specific route wins.
      ip route replace "$gateway/32" dev ${ns}0

      now=$(date -u +%s)
      need_sig=1
      if [ -n "$payload" ] && [ -n "$signature" ] && [ -n "$expires" ]; then
        exp_ts=$(date -u -d "$expires" +%s 2>/dev/null || echo 0)
        # Renew a day before expiry to be safe.
        if [ "$exp_ts" -gt "$((now + 86400))" ]; then need_sig=0; fi
      fi

      if [ "$need_sig" -eq 1 ]; then
        echo "pia-pf: requesting new port-forward signature" >&2
        resp=$(curl -fsSL -m 10 -G \
          --connect-to "$hostname::$gateway:" \
          --cacert "${caCert}" \
          --data-urlencode "token=$token" \
          "https://$hostname:19999/getSignature")
        [ "$(echo "$resp" | jq -r '.status')" = "OK" ] || { echo "pia-pf: getSignature failed: $resp" >&2; exit 1; }
        payload=$(echo "$resp" | jq -r '.payload')
        signature=$(echo "$resp" | jq -r '.signature')
        decoded=$(echo "$payload" | base64 -d)
        port=$(echo "$decoded" | jq -r '.port')
        expires=$(echo "$decoded" | jq -r '.expires_at')
      else
        port=$(echo "$payload" | base64 -d | jq -r '.port')
      fi

      echo "pia-pf: binding port $port" >&2
      bind=$(curl -fsSL -m 10 -G \
        --connect-to "$hostname::$gateway:" \
        --cacert "${caCert}" \
        --data-urlencode "payload=$payload" \
        --data-urlencode "signature=$signature" \
        "https://$hostname:19999/bindPort")
      [ "$(echo "$bind" | jq -r '.status')" = "OK" ] || { echo "pia-pf: bindPort failed: $bind" >&2; exit 1; }

      # Persist signature/port (root-only) and publish the bare port for consumers.
      tmp=$(mktemp)
      echo "$state" | jq \
        --arg payload "$payload" --arg signature "$signature" \
        --arg expires "$expires" --argjson port "$port" \
        '. + {payload: $payload, signature: $signature, expires_at: $expires, port: $port}' > "$tmp"
      install -m 0600 "$tmp" "${statePath}"
      rm -f "$tmp"
      install -d -m 0755 /run/pia
      printf '%s\n' "$port" > "${portFilePath}"
      chmod 0644 "${portFilePath}"

      # Reconcile the namespace firewall + notify consumers only on change.
      if [ "$applied" != "$port" ]; then
        if [ -n "$applied" ]; then
          iptables -D INPUT -i ${ns}0 -p tcp --dport "$applied" -j ACCEPT 2>/dev/null || true
          iptables -D INPUT -i ${ns}0 -p udp --dport "$applied" -j ACCEPT 2>/dev/null || true
        fi
        iptables -C INPUT -i ${ns}0 -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
          || iptables -A INPUT -i ${ns}0 -p tcp --dport "$port" -j ACCEPT
        iptables -C INPUT -i ${ns}0 -p udp --dport "$port" -j ACCEPT 2>/dev/null \
          || iptables -A INPUT -i ${ns}0 -p udp --dport "$port" -j ACCEPT

        echo "pia-pf: forwarded port changed ''${applied:-none} -> $port; dispatching consumers" >&2
        ${hookScript} "$port"

        tmp=$(mktemp)
        cat "${statePath}" | jq --argjson port "$port" '. + {applied_port: $port}' > "$tmp"
        install -m 0600 "$tmp" "${statePath}"
        rm -f "$tmp"
      else
        echo "pia-pf: port unchanged ($port); rebind kept alive" >&2
      fi
    '';
  };

  # Web-UI port mappings derived from declared consumers.
  consumerPortMappings =
    mapAttrsToList (_: c: {
      from = c.port;
      to = c.port;
      protocol = "tcp";
    })
    (filterAttrs (_: c: c.port != null) cfg.consumers);
in {
  options.constellation.pia = {
    enable = mkEnableOption "PIA VPN namespace with dynamic port forwarding";

    credentialsFile = mkOption {
      type = types.path;
      default = config.sops.secrets."pia-credentials".path;
      defaultText = literalExpression ''config.sops.secrets."pia-credentials".path'';
      description = ''
        Path to an env file exporting PIA_USER and PIA_PASS for the PIA account.
      '';
    };

    region = mkOption {
      type = types.str;
      default = "auto";
      example = "ca_toronto";
      description = ''
        PIA region id to connect to, or "auto" for the first port-forward-capable
        region. US regions do not support port forwarding.
      '';
    };

    namespace = mkOption {
      type = types.str;
      default = "pia";
      description = "Name of the VPN-Confinement network namespace.";
    };

    namespaceAddress = mkOption {
      type = types.str;
      default = "192.168.16.1";
      description = ''
        Service-side namespace address (where the gateway proxies). Must not
        collide with the AirVPN namespace subnet (192.168.15.0/24).
      '';
    };

    bridgeAddress = mkOption {
      type = types.str;
      default = "192.168.16.5";
      description = "Host-side bridge address for the namespace veth pair.";
    };

    portFile = mkOption {
      type = types.path;
      default = portFilePath;
      readOnly = true;
      description = "World-readable file holding the current forwarded port as a bare integer.";
    };

    consumers = mkOption {
      default = {};
      description = ''
        Apps attached to the PIA namespace. Each consumer's onPortChange runs
        with the forwarded port in $PIA_FORWARDED_PORT whenever it changes.
      '';
      example = literalExpression ''
        {
          rqbit = {
            port = 3030;
            onPortChange = "systemctl restart rqbit";
          };
        }
      '';
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          onPortChange = mkOption {
            type = types.lines;
            description = "Shell run (with $PIA_FORWARDED_PORT set) when the port changes.";
          };
          port = mkOption {
            type = types.nullOr types.port;
            default = null;
            description = "Web-UI port to map from host into the namespace (null = none).";
          };
          host = mkOption {
            type = types.str;
            default = cfg.namespaceAddress;
            description = "Namespace IP the gateway should proxy this consumer's web UI to.";
          };
        };
      }));
    };
  };

  config = mkIf cfg.enable {
    sops.secrets."pia-credentials" = mkDefault {mode = "0400";};

    # PIA WireGuard namespace, alongside the AirVPN "wg" namespace.
    vpnNamespaces.${ns} = {
      enable = true;
      wireguardConfigFile = wgConfPath;
      namespaceAddress = cfg.namespaceAddress;
      bridgeAddress = cfg.bridgeAddress;
      accessibleFrom = [
        "100.64.0.0/10" # Tailscale CGNAT
        "10.0.0.0/8" # Local networks (incl. Podman)
        "192.168.0.0/16"
      ];
      portMappings = consumerPortMappings;
      # The forwarded peer port is dynamic and opened at runtime by the PF daemon
      # (openVPNPorts is build-time only, so it can't carry the assigned port).
      openVPNPorts = [];
    };

    systemd.services.pia-connect = {
      description = "PIA: authenticate and generate WireGuard tunnel config";
      after = ["network-online.target" "nss-lookup.target"];
      wants = ["network-online.target" "nss-lookup.target"];
      before = ["${ns}.service"];
      requiredBy = ["${ns}.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${connectScript}/bin/pia-connect";
        StateDirectory = "pia";
      };
    };

    systemd.services.pia-portforward = {
      description = "PIA: acquire and bind the forwarded port";
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
        ExecStart = "${portforwardScript}/bin/pia-portforward";
        StateDirectory = "pia";
      };
    };

    systemd.timers.pia-portforward = {
      description = "PIA: re-bind the forwarded port (15-min keepalive)";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnActiveSec = "15min";
        OnUnitActiveSec = "15min";
        Persistent = true;
      };
    };
  };
}
