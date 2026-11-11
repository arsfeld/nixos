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
#   pia-portforward-refresh.timer re-binds every 14 minutes (PIA keepalive)
#   pia-watchdog.timer restarts <ns> when the WireGuard handshake goes stale
#
# PIA port forwarding is dynamic: PIA assigns the port (payload valid ~60 days),
# and the binding must be refreshed every <=15 minutes. The port is cached so it
# survives reboots and rebinds without requesting a new signature.
#
# NOTE: This module is build-verified. The PIA API flow (ported from
# pia-foss/manual-connections) requires valid PIA credentials and a galactica
# deploy to verify at runtime.
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

    statePath = "/var/lib/pia/state.json"; # root-only: token, payload, signature
    wgConfPath = "/run/pia/wg0.conf"; # root-only: WireGuard private key
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

    # PIA control-plane script with two subcommands:
    #   connect      (U3, host netns) authenticate, register an ephemeral
    #                WireGuard key, write the tunnel config + state cache.
    #   portforward  (U4, inside <ns>) acquire/refresh the PF signature, bind it
    #                (15-min keepalive), open the dynamic port on the tunnel
    #                interface, and dispatch consumer hooks on change.
    #
    # HTTPS still goes through curl so PIA's --connect-to (pin to the gateway IP
    # but validate the cert against the server CN) and pinned-CA behavior are
    # preserved byte-for-byte; Python owns the JSON, state, and control flow.
    # wg/ip/iptables are invoked by absolute path. The consumer hook stays shell
    # since onPortChange is arbitrary user shell.
    piaScript = pkgs.writeScriptBin "pia" ''
      #!${pkgs.python3}/bin/python3
      import base64
      import datetime
      import json
      import os
      import subprocess
      import sys
      import time

      CURL = "${pkgs.curl}/bin/curl"
      WG = "${pkgs.wireguard-tools}/bin/wg"
      IP = "${pkgs.iproute2}/bin/ip"
      IPTABLES = "${pkgs.iptables}/bin/iptables"

      CRED_FILE = "${cfg.credentialsFile}"
      REGION = "${cfg.region}"
      CA_CERT = "${caCert}"
      WG_CONF = "${wgConfPath}"
      STATE = "${statePath}"
      PORT_FILE = "${portFilePath}"
      HOOK = "${hookScript}"
      NS_IF = "${ns}0"


      def log(msg):
          print("pia: " + msg, file=sys.stderr, flush=True)


      def die(msg):
          print("pia: " + msg, file=sys.stderr, flush=True)
          sys.exit(1)


      def curl(args):
          # -fsSL matches the original: fail on HTTP errors, silent, follow redirects.
          proc = subprocess.run([CURL, "-fsSL", *args], capture_output=True, text=True)
          if proc.returncode != 0:
              die("curl failed (" + str(proc.returncode) + "): " + proc.stderr.strip())
          return proc.stdout


      def curl_json(args):
          return json.loads(curl(args))


      def read_state():
          if os.path.exists(STATE):
              with open(STATE) as f:
                  return json.load(f)
          return {}


      def write_json(path, data, mode):
          tmp = path + ".tmp"
          with open(tmp, "w") as f:
              json.dump(data, f)
          os.chmod(tmp, mode)
          os.replace(tmp, path)


      def parse_ts(value):
          value = value.strip()
          if value.endswith("Z"):
              value = value[:-1] + "+00:00"
          try:
              return int(datetime.datetime.fromisoformat(value).timestamp())
          except ValueError:
              return 0


      def load_credentials():
          # The credentials file is a small env file (optionally with "export ").
          user = None
          password = None
          with open(CRED_FILE) as f:
              for raw in f:
                  line = raw.strip()
                  if not line or line.startswith("#"):
                      continue
                  if line.startswith("export "):
                      line = line[len("export "):]
                  if "=" not in line:
                      continue
                  key, val = line.split("=", 1)
                  val = val.strip().strip('"').strip("'")
                  if key.strip() == "PIA_USER":
                      user = val
                  elif key.strip() == "PIA_PASS":
                      password = val
          if not user:
              die("missing PIA_USER in credentials file")
          if not password:
              die("missing PIA_PASS in credentials file")
          return user, password


      def connect():
          user, password = load_credentials()

          # /run/pia is traversable so consumers can read the bare port file;
          # wg0.conf inside it stays 0600 (holds the private key).
          os.makedirs("/run/pia", exist_ok=True)
          os.chmod("/run/pia", 0o755)
          os.makedirs("/var/lib/pia", exist_ok=True)
          os.chmod("/var/lib/pia", 0o700)

          log("requesting auth token")
          token = curl_json([
              "-X", "POST",
              "https://www.privateinternetaccess.com/api/client/v2/token",
              "--form", "username=" + user,
              "--form", "password=" + password,
          ]).get("token")
          if not token:
              die("token request failed")

          log("fetching server list")
          # The v6 server list prepends a signature line; the first line is JSON.
          raw = curl(["https://serverlist.piaservers.net/vpninfo/servers/v6"])
          regions = json.loads(raw.splitlines()[0]).get("regions", [])

          if REGION == "auto":
              sel = next((r for r in regions if r.get("port_forward")), None)
          else:
              sel = next((r for r in regions if r.get("id") == REGION), None)
          if sel is None:
              die("no matching region for '" + REGION + "'")
          if not sel.get("port_forward"):
              die("region '" + REGION + "' does not support port forwarding (US regions never do)")

          wg = sel["servers"]["wg"][0]
          wg_ip = wg["ip"]
          wg_cn = wg["cn"]
          log("selected region '" + str(sel.get("id")) + "' server " + wg_cn + " (" + wg_ip + ")")

          priv = subprocess.run([WG, "genkey"], capture_output=True, text=True, check=True).stdout.strip()
          pub = subprocess.run([WG, "pubkey"], input=priv + "\n", capture_output=True, text=True, check=True).stdout.strip()

          log("registering key with " + wg_cn)
          addkey = curl_json([
              "-G",
              "--connect-to", wg_cn + "::" + wg_ip + ":",
              "--cacert", CA_CERT,
              "--data-urlencode", "pt=" + token,
              "--data-urlencode", "pubkey=" + pub,
              "https://" + wg_cn + ":1337/addKey",
          ])
          if addkey.get("status") != "OK":
              die("addKey failed: " + json.dumps(addkey))

          dns_servers = addkey.get("dns_servers") or []
          dns = dns_servers[0] if dns_servers else ""
          conf = "\n".join([
              "[Interface]",
              "Address = " + addkey["peer_ip"],
              "PrivateKey = " + priv,
              "DNS = " + dns,
              "",
              "[Peer]",
              "PersistentKeepalive = 25",
              "PublicKey = " + addkey["server_key"],
              "AllowedIPs = 0.0.0.0/0",
              "Endpoint = " + str(addkey["server_ip"]) + ":" + str(addkey["server_port"]),
              "",
          ])
          tmp = WG_CONF + ".tmp"
          with open(tmp, "w") as f:
              f.write(conf)
          os.chmod(tmp, 0o600)
          os.replace(tmp, WG_CONF)

          # Persist what the PF daemon needs. Preserve any existing payload/port so
          # a reconnect with the same account can keep rebinding the same port
          # until expiry. (The payload is tied to the token, not the tunnel.)
          state = read_state()
          state.update({
              "token": token,
              "pf_gateway": addkey["server_vip"],
              "pf_hostname": wg_cn,
              "dns_servers": dns_servers,
          })
          write_json(STATE, state, 0o600)
          log("tunnel config written; gateway " + addkey["server_vip"])


      def iptables_del(port):
          for proto in ("tcp", "udp"):
              subprocess.run(
                  [IPTABLES, "-D", "INPUT", "-i", NS_IF, "-p", proto, "--dport", str(port), "-j", "ACCEPT"],
                  capture_output=True, text=True,
              )


      def iptables_ensure(port):
          for proto in ("tcp", "udp"):
              check = subprocess.run(
                  [IPTABLES, "-C", "INPUT", "-i", NS_IF, "-p", proto, "--dport", str(port), "-j", "ACCEPT"],
                  capture_output=True, text=True,
              )
              if check.returncode != 0:
                  subprocess.run(
                      [IPTABLES, "-A", "INPUT", "-i", NS_IF, "-p", proto, "--dport", str(port), "-j", "ACCEPT"],
                      check=True,
                  )


      def portforward():
          state = read_state()
          if not state:
              die("no state yet (connect not run)")
          token = state.get("token")
          gateway = state.get("pf_gateway")
          hostname = state.get("pf_hostname")
          payload = state.get("payload") or ""
          signature = state.get("signature") or ""
          expires = state.get("expires_at") or ""
          applied = state.get("applied_port")

          # The namespace's accessibleFrom 10.0.0.0/8 route (to the host bridge)
          # would otherwise capture the PF gateway VIP (also in 10/8) and send
          # getSignature back out the veth instead of through the tunnel. Pin a /32
          # host route via the tunnel so the more-specific route wins.
          subprocess.run([IP, "route", "replace", gateway + "/32", "dev", NS_IF], check=True)

          # Same collision hits PIA's tunnel-internal DNS server(s): PIA hands out a
          # resolver in 10/8 (e.g. 10.0.0.243, which can overlap the local LAN /24),
          # so the accessibleFrom route would send DNS out the veth to the host
          # where it is unreachable. Resolvers that honor resolv.conf then fail
          # every lookup (this bit rqbit's bundled hickory). Pin every DNS server
          # via the tunnel. Re-derived from PIA's API each connect/rebind, so it
          # follows any change PIA makes.
          for dns in state.get("dns_servers") or []:
              if dns:
                  subprocess.run([IP, "route", "replace", str(dns) + "/32", "dev", NS_IF], check=True)

          now = int(time.time())
          need_sig = True
          if payload and signature and expires:
              # Renew a day before expiry to be safe.
              if parse_ts(expires) > now + 86400:
                  need_sig = False

          if need_sig:
              log("requesting new port-forward signature")
              resp = curl_json([
                  "-m", "10", "-G",
                  "--connect-to", hostname + "::" + gateway + ":",
                  "--cacert", CA_CERT,
                  "--data-urlencode", "token=" + token,
                  "https://" + hostname + ":19999/getSignature",
              ])
              if resp.get("status") != "OK":
                  die("getSignature failed: " + json.dumps(resp))
              payload = resp["payload"]
              signature = resp["signature"]
              decoded = json.loads(base64.b64decode(payload))
              port = decoded["port"]
              expires = decoded["expires_at"]
          else:
              port = json.loads(base64.b64decode(payload))["port"]

          log("binding port " + str(port))
          bind = curl_json([
              "-m", "10", "-G",
              "--connect-to", hostname + "::" + gateway + ":",
              "--cacert", CA_CERT,
              "--data-urlencode", "payload=" + payload,
              "--data-urlencode", "signature=" + signature,
              "https://" + hostname + ":19999/bindPort",
          ])
          if bind.get("status") != "OK":
              die("bindPort failed: " + json.dumps(bind))

          # Persist signature/port (root-only) and publish the bare port for
          # consumers. applied_port is left untouched until the hook succeeds, so a
          # failed dispatch is retried on the next run.
          state["payload"] = payload
          state["signature"] = signature
          state["expires_at"] = expires
          state["port"] = port
          write_json(STATE, state, 0o600)

          os.makedirs("/run/pia", exist_ok=True)
          os.chmod("/run/pia", 0o755)
          tmp = PORT_FILE + ".tmp"
          with open(tmp, "w") as f:
              f.write(str(port) + "\n")
          os.chmod(tmp, 0o644)
          os.replace(tmp, PORT_FILE)

          # Open the peer port unconditionally, not just on change: restarting
          # <ns>.service recreates the namespace and wipes its firewall, while
          # applied_port persists in state.json. Gating this on a change would
          # leave the peer port closed after every such restart (no inbound peers,
          # silently). iptables_ensure is idempotent, so re-running it is free.
          iptables_ensure(port)

          # Retiring the old rule and notifying consumers only makes sense on change.
          if applied != port:
              if applied is not None:
                  iptables_del(applied)
              log("forwarded port changed " + (str(applied) if applied is not None else "none") + " -> " + str(port) + "; dispatching consumers")
              subprocess.run([HOOK, str(port)], check=True)
              state["applied_port"] = port
              write_json(STATE, state, 0o600)
          else:
              log("port unchanged (" + str(port) + "); rebind kept alive")


      def main():
          if len(sys.argv) < 2:
              die("usage: pia <connect|portforward>")
          cmd = sys.argv[1]
          if cmd == "connect":
              connect()
          elif cmd == "portforward":
              portforward()
          else:
              die("unknown subcommand: " + cmd)


      main()
    '';

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

    config = {
      sops.secrets."pia-credentials" = lib.mkDefault {mode = "0400";};

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
        # Restarting the tunnel (a deploy, a manual restart) must re-run connect.
        # Otherwise this RemainAfterExit oneshot stays "active" and the tunnel comes
        # back up against the server cached in wg0.conf, which PIA may have retired
        # since: pia-up then dies with "failed to reach '<ip>' after 5 attempts".
        partOf = ["${ns}.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${piaScript}/bin/pia connect";
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
          ExecStart = "${piaScript}/bin/pia portforward";
          StateDirectory = "pia";
        };
      };

      # The keepalive runs as its own unit. A timer cannot re-run pia-portforward:
      # starting a RemainAfterExit unit that is already active is a no-op, so the
      # timer fired once after boot, never again (NextElapse=infinity), and the
      # binding lapsed 15 minutes after every start.
      systemd.services.pia-portforward-refresh = {
        description = "PIA: re-bind the forwarded port (keepalive)";
        after = ["${ns}.service" "pia-portforward.service"];
        # Never bring the tunnel up from here; that is pia-watchdog's job.
        requisite = ["${ns}.service"];
        vpnConfinement = {
          enable = true;
          vpnNamespace = ns;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${piaScript}/bin/pia portforward";
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

      # Nothing else notices a dead tunnel: every unit stays "active" while the
      # namespace has no route out. On 2026-11-09 the server stopped answering and
      # Transmission sat idle for 2.5 days. With PersistentKeepalive = 25 a live
      # peer re-handshakes every 2 minutes, so a handshake older than 5 minutes
      # means the server is gone; restarting the namespace re-runs pia-connect,
      # which registers a fresh key on a server picked from the current list.
      systemd.services.pia-watchdog = {
        description = "PIA: restart the tunnel when its handshake goes stale";
        after = ["${ns}.service"];
        path = [pkgs.iproute2 pkgs.wireguard-tools pkgs.systemd pkgs.coreutils];
        serviceConfig.Type = "oneshot";
        script = ''
          set -u
          stale=300
          now=$(date +%s)
          if systemctl is-active --quiet ${ns}.service; then
            up=$(systemctl show -P ActiveEnterTimestamp --timestamp=unix ${ns}.service)
            up_age=$(( now - ''${up#@} ))
            # Give a fresh tunnel time for its first handshake.
            if [ "$up_age" -lt "$stale" ]; then exit 0; fi
            hs=$(ip netns exec ${ns} wg show ${ns}0 latest-handshakes 2>/dev/null | cut -f2 | sort -n | tail -n1)
            age=$(( now - ''${hs:-0} ))
            if [ "$age" -lt "$stale" ]; then exit 0; fi
            echo "pia-watchdog: last handshake ''${age}s ago; restarting ${ns}.service" >&2
          else
            echo "pia-watchdog: ${ns}.service is not active; restarting it" >&2
          fi
          systemctl restart ${ns}.service
        '';
      };

      systemd.timers.pia-watchdog = {
        description = "PIA: check the tunnel handshake every 2 minutes";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "2min";
        };
      };
    };
  };
}
