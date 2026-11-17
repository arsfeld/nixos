# PIA exit slots: Tailscale exit nodes whose country is picked in Home Assistant.
# Design: docs/superpowers/specs/2026-11-16-pia-exit-nodes-design.md
#
# Each slot is its own PIA WireGuard namespace (piax<n>) with a userspace-networking
# tailscaled confined to it, advertised as an exit node. The namespace's only route
# out is the tunnel, so a dead tunnel drops forwarded traffic instead of leaking it
# through galactica's WAN.
#
# Every slot unit belongs to pia-exit-<n>.target, and nothing wants that target:
# pia-exits.service (`pia exits serve`) starts the slots that have a region file at
# boot and starts, restarts and stops them when HA picks a region, through
# 127.0.0.1:8592. A device remembers its exit node by node ID, so it follows its slot
# whatever country the slot is set to.
{
  configurations.nixos.galactica.module = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.constellation.piaExits;
    mkPiaTunnel = import ./_pia/tunnel.nix {inherit lib pkgs;};
    pia = lib.getExe pkgs.pia;
    tailscalePkg = config.services.tailscale.package;
    listen = "127.0.0.1:8592";

    slot = n: let
      s = toString n;
    in rec {
      inherit n;
      namespace = "piax${s}";
      target = "pia-exit-${s}.target";
      # 41641 is the host tailscaled's.
      port = 41641 + n;
      stateDir = "tailscale-piax${s}";
      socket = "/run/tailscale-piax${s}/tailscaled.sock";
      regionFile = "/var/lib/pia-exits/slot-${s}";
      # Clear of the LAN (.18), AirVPN (.15) and Transmission's pia (.16).
      subnet = "192.168.${toString (100 + n)}";
      tunnel = mkPiaTunnel {
        inherit namespace target;
        connectUnit = "pia-connect-x${s}";
        watchdogUnit = "pia-watchdog-x${s}";
        namespaceAddress = "${subnet}.1";
        bridgeAddress = "${subnet}.5";
        env =
          config.constellation.pia.baseEnv
          // {
            PIA_NAMESPACE = namespace;
            PIA_REGION_FILE = regionFile;
            PIA_RUN_DIR = "/run/pia-x${s}";
            PIA_STATE_DIR = "/var/lib/pia-x${s}";
            PIA_PORT_FORWARD = "0";
          };
      };
    };
    slots = map slot (lib.range 1 cfg.slots);

    exitsConfig = pkgs.writeText "pia-exits.json" (builtins.toJSON {
      inherit listen;
      ip = config.constellation.pia.baseEnv.PIA_IP;
      wg = config.constellation.pia.baseEnv.PIA_WG;
      systemctl = config.constellation.pia.baseEnv.PIA_SYSTEMCTL;
      tailscale = "${tailscalePkg}/bin/tailscale";
      curl = "${pkgs.curl}/bin/curl";
      oauth_key = config.sops.secrets.tailscale-key.path;
      slots =
        map (sl: {
          slot = sl.n;
          inherit (sl) namespace target socket port;
          # VPN-Confinement names a namespace's WireGuard interface <namespace>0.
          interface = "${sl.namespace}0";
          region_file = sl.regionFile;
        })
        slots;
    });

    slotUnits = sl: {
      targets."pia-exit-${toString sl.n}" = {
        description = "PIA exit slot ${toString sl.n}";
      };

      services."tailscaled-${sl.namespace}" = {
        description = "Tailscale for PIA exit slot ${toString sl.n}";
        # Also wanted by the namespace: a deploy that changes only the namespace unit
        # stops it (taking this down through BindsTo/PartOf) and starts it again, and
        # nothing else would start this. The namespace itself is wanted only by the
        # target, so with the slot Off neither starts.
        wantedBy = [sl.target "${sl.namespace}.service"];
        partOf = ["${sl.namespace}.service" sl.target];
        vpnConfinement = {
          enable = true;
          vpnNamespace = sl.namespace;
        };
        serviceConfig = {
          Type = "notify";
          # Userspace networking turns forwarded flows into sockets inside the
          # namespace: no ip_forward or NAT there, and the host's tailscaled,
          # tailscale0 and routing table 52 are never touched.
          ExecStart = lib.concatStringsSep " " [
            "${tailscalePkg}/bin/tailscaled"
            "--tun=userspace-networking"
            "--statedir=/var/lib/${sl.stateDir}"
            "--socket=${sl.socket}"
            "--port=${toString sl.port}"
          ];
          StateDirectory = sl.stateDir;
          RuntimeDirectory = sl.stateDir;
          Restart = "on-failure";
        };
      };

      services."tailscale-${sl.namespace}-up" = {
        description = "Tailscale login and naming for PIA exit slot ${toString sl.n}";
        # See tailscaled-<namespace> above.
        wantedBy = [sl.target "${sl.namespace}.service"];
        after = ["tailscaled-${sl.namespace}.service"];
        requires = ["tailscaled-${sl.namespace}.service"];
        partOf = ["${sl.namespace}.service" sl.target];
        environment.PIA_EXITS_CONFIG = "${exitsConfig}";
        serviceConfig = {
          Type = "oneshot";
          # Active while the slot runs, so a restart of the target re-runs it and
          # renames the node for the new region.
          RemainAfterExit = true;
          # A hung `tailscale up` must not hold the target in "activating" forever.
          TimeoutStartSec = 120;
          # Holds the login key file; root, so it reads the OAuth secret directly.
          RuntimeDirectory = "tailscale-${sl.namespace}-up";
          ExecStart = "${pia} exits node ${toString sl.n}";
        };
      };
    };

    # Jinja that binds `s` to the slot list, empty when the answer has none, so a
    # slot past its end reads as missing rather than raising.
    slotList = expr: "{% set s = ${expr} or [] %}";
    slotField = sl: field: let
      i = toString (sl.n - 1);
    in "(s[${i}].${field} if s | length > ${i} else none)";

    # JSON null (no egress check yet, no hostname) is `unknown`, never the text "None".
    statusSensor = sl: field: what: {
      name = "PIA exit ${toString sl.n} ${what}";
      unique_id = "pia_exit_${toString sl.n}_${what}";
      value_template = "${slotList "value_json.slots"}{{ ${slotField sl field} or 'unknown' }}";
    };
  in {
    options.constellation.piaExits.slots = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = ''
        Number of PIA exit slots. Each is one Tailscale exit node whose PIA region is
        chosen in Home Assistant, and one PIA connection while it is not Off.
      '';
    };

    config = {
      assertions = [
        {
          assertion = cfg.slots >= 1 && cfg.slots <= 9;
          message = "constellation.piaExits.slots must be between 1 and 9.";
        }
      ];

      vpnNamespaces = lib.mkMerge (map (sl: sl.tunnel.vpnNamespaces) slots);

      systemd = lib.mkMerge (
        map (sl: sl.tunnel.systemd) slots
        ++ map slotUnits slots
        ++ [
          {
            services.pia-exits = {
              description = "PIA exit slots: control API for Home Assistant";
              wantedBy = ["multi-user.target"];
              after = ["network-online.target"];
              wants = ["network-online.target"];
              environment.PIA_EXITS_CONFIG = "${exitsConfig}";
              serviceConfig = {
                # Root: it starts and stops the slot targets and reads WireGuard
                # state inside the namespaces.
                ExecStart = "${pia} exits serve";
                StateDirectory = "pia-exits";
                Restart = "always";
                RestartSec = 5;
              };
            };
          }
        ]
      );

      services.home-assistant.config = {
        rest = [
          {
            resource = "http://${listen}/status";
            scan_interval = 30;
            sensor =
              [
                {
                  name = "PIA exits";
                  unique_id = "pia_exits";
                  value_template = "{{ value_json.active }}";
                  json_attributes = ["options" "slots"];
                }
              ]
              ++ lib.concatMap (sl: [
                (statusSensor sl "state" "state")
                (statusSensor sl "egress_ip" "ip")
                (statusSensor sl "egress_country" "country")
                (statusSensor sl "hostname" "node")
              ])
              slots;
            binary_sensor =
              map (sl: {
                name = "PIA exit ${toString sl.n} working";
                unique_id = "pia_exit_${toString sl.n}_working";
                value_template = "${slotList "value_json.slots"}{{ ${slotField sl "state"} == 'up' }}";
              })
              slots;
          }
        ];

        rest_command.pia_exit_set = {
          url = "http://${listen}/slots/{{ slot }}";
          method = "post";
          content_type = "application/json";
          payload = "{\"option\": \"{{ option }}\"}";
        };

        template = [
          {
            select =
              map (sl: {
                name = "PIA exit ${toString sl.n}";
                unique_id = "pia_exit_${toString sl.n}";
                options = "{{ state_attr('sensor.pia_exits','options') or ['Off'] }}";
                state = "${slotList "state_attr('sensor.pia_exits','slots')"}{{ ${slotField sl "option"} or 'Off' }}";
                select_option = [
                  {
                    action = "rest_command.pia_exit_set";
                    data = {
                      slot = sl.n;
                      option = "{{ option }}";
                    };
                  }
                  # Show the change now rather than at the next 30 s poll.
                  {
                    action = "homeassistant.update_entity";
                    target.entity_id = "sensor.pia_exits";
                  }
                ];
              })
              slots;
          }
        ];

        # The option list is a few KB on every poll and never interesting in history.
        recorder.exclude.entities = ["sensor.pia_exits"];
      };
    };
  };
}
