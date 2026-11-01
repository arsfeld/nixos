# Constellation Home Assistant module
#
# This module provides Home Assistant home automation platform with support
# for custom integrations via HACS (Home Assistant Community Store).
#
# Key features:
# - Writable configuration for UI-managed automations and HACS installations
# - Built-in support for ESPHome, Met.no weather, TP-Link Kasa, and default integrations
# - Custom components for Tuya Local, Alarmo, Hilo, Eufy Security (eufy-sdk)
#   Tuya IR air conditioners, Midea-protocol IR air conditioners, and TP-Link Deco
# - Trusted proxy configuration for reverse proxy integration
# - UI-managed automation, scene, and script files
# - Heating automations live in ./home-assistant-heating/
# - Network quality history (ping + Speedtest.net); see "automation network"
#
# Prefer packaging a component over installing it through HACS: pip is
# disabled here, so a HACS-installed component whose Python requirements are
# not in the Nix environment cannot load.
#
# The module enables configWritable to allow HACS to install custom integrations
# and the UI to modify automation files. Configuration changes made through the
# Home Assistant UI will persist across system rebuilds.
#
# Access:
# - Default port: 8123
# - Should be exposed via constellation.services for reverse proxy access
{
  configurations.nixos.galactica.module = {pkgs, ...}: let
    # Ping config entries (added in the UI, see "automation network"), by the
    # entity-id prefix HA derived from each host. Labels are what the graphs show.
    pingTargets = [
      {
        id = "raider_local";
        name = "raider (mesh)";
      }
      {
        id = "basestar_bat_boa_ts_net";
        name = "basestar (Tailscale)";
      }
      {
        id = "1_1_1_1";
        name = "1.1.1.1";
      }
    ];
    pingEntities = metric:
      map (t: {
        entity = "sensor.${t.id}_${metric}";
        inherit (t) name;
      })
      pingTargets;
    speedtest = [
      {
        entity = "sensor.speedtest_download";
        name = "Download";
      }
      {
        entity = "sensor.speedtest_upload";
        name = "Upload";
      }
    ];

    # YAML-mode dashboard: declared here, read-only in the UI. The Home
    # dashboard stays UI-managed; HA cannot mix a YAML view into it.
    networkDashboard = (pkgs.formats.yaml {}).generate "network-dashboard.yaml" {
      title = "Network";
      views = [
        {
          title = "Network";
          path = "network";
          type = "sections";
          max_columns = 2;
          sections = [
            {
              title = "Latency";
              cards = [
                {
                  type = "history-graph";
                  title = "Round-trip average, 48 h";
                  hours_to_show = 48;
                  entities = pingEntities "round_trip_time_average";
                }
                {
                  type = "history-graph";
                  title = "Jitter, 48 h";
                  hours_to_show = 48;
                  entities = pingEntities "jitter";
                }
                {
                  type = "statistics-graph";
                  title = "Round-trip average, 30 days (hourly mean)";
                  days_to_show = 30;
                  period = "hour";
                  chart_type = "line";
                  stat_types = ["mean"];
                  entities = pingEntities "round_trip_time_average";
                }
                {
                  type = "history-graph";
                  title = "Packet loss, 7 days";
                  hours_to_show = 168;
                  entities = pingEntities "packet_loss";
                }
              ];
            }
            {
              title = "Internet";
              cards = [
                {
                  type = "entities";
                  title = "Last speed test";
                  entities =
                    speedtest
                    ++ [
                      {
                        entity = "sensor.speedtest_ping";
                        name = "Ping";
                      }
                    ];
                }
                {
                  type = "statistics-graph";
                  title = "Throughput, 30 days";
                  days_to_show = 30;
                  period = "day";
                  chart_type = "line";
                  stat_types = ["mean" "min" "max"];
                  entities = speedtest;
                }
                {
                  type = "history-graph";
                  title = "Speed tests, 7 days";
                  hours_to_show = 168;
                  entities = speedtest;
                }
              ];
            }
            {
              title = "Deco mesh";
              cards = [
                {
                  type = "entities";
                  title = "Nodes";
                  entities = [
                    "binary_sensor.garage_deco_internet_online"
                    "binary_sensor.living_room_deco_deco_online"
                    "binary_sensor.basement_deco_deco_online"
                    "sensor.garage_deco_connected_clients"
                    "sensor.living_room_deco_connected_clients"
                    "sensor.basement_deco_connected_clients"
                  ];
                }
                {
                  type = "history-graph";
                  title = "Mesh traffic (main node), 48 h";
                  hours_to_show = 48;
                  entities = [
                    "sensor.garage_deco_total_down"
                    "sensor.garage_deco_total_up"
                  ];
                }
              ];
            }
          ];
        }
      ];
    };
  in {
    config = {
      media.services.hass = {
        port = 8123;
        tailscaleExposed = true;
        bypassAuth = true;
      };

      services.home-assistant = {
        enable = true;

        # Allow HACS and UI modifications to persist
        configWritable = true;

        # Core integrations to include
        extraComponents = [
          "default_config" # Includes common integrations (sun, person, zone, etc.)
          "met" # Met.no weather integration
          "esphome" # ESPHome device integration
          "tplink" # Kasa/Tapo switches (local; KLAP devices need the TP-Link account)
          "tuya" # Smart Life cloud; configured in the UI, so its deps must be listed here

          # Apple integrations
          "homekit" # Apple HomeKit Bridge (exposes HA entities to Apple Home)
          "homekit_controller" # Apple HomeKit Device (pairs HomeKit accessories directly)
          "apple_tv" # Apple TV media player and remote
          "icloud" # Apple iCloud device tracker and Find My

          # Common core integrations
          "mqtt" # MQTT broker integration
          "matter" # Matter devices
          "zha" # Zigbee Home Automation
          "cast" # Google Cast / Chromecast / Google Home
          "plex" # Plex Media Server
          "shelly" # Shelly WiFi devices and sensors
          "wled" # WLED addressable LED controllers
          "sonos" # Sonos media players
          "spotify" # Spotify media player
          "ping" # Ping (ICMP) network presence detection
          "speedtestdotnet" # Internet speed; polled only by "automation network"
          "wake_on_lan" # Wake on LAN

          # Found by default_config's discovery; without their deps every
          # discovery round logs a failed flow.
          "hue" # Philips Hue bridge
          "androidtv_remote" # Android TV / Google TV
          "upnp" # UPnP/IGD router
          "google_translate" # Google Translate TTS, set up in the UI
        ];

        # Custom components from nixpkgs, plus the ones packaged in ./packages
        customComponents = with pkgs.home-assistant-custom-components; [
          tuya_local # Local control of Tuya devices
          alarmo # Security system integration
          pkgs.home-assistant-hilo # Hydro-Québec Hilo
          pkgs.home-assistant-eufy-sdk # Eufy Security, via the eufy-sdk-bridge container
          pkgs.home-assistant-tuya-smart-ir-ac # IR air conditioners behind Tuya Smart IR hubs
          pkgs.home-assistant-midea-ir # Midea-protocol IR ACs, encoded locally
          pkgs.home-assistant-tplink-deco # TP-Link Deco mesh nodes and clients
        ];

        # Dashboard cards. Setting this switches lovelace resources to YAML mode,
        # so cards come from here, not from HACS; dashboards stay UI-editable.
        customLovelaceModules = with pkgs.home-assistant-custom-lovelace-modules; [
          mushroom
        ];

        # Extra Python packages required by HACS and custom integrations
        extraPackages = ps: [
          ps.aiogithubapi # Required by HACS
        ];

        # Base configuration
        config = {
          # extraComponents only installs default_config's dependencies; it is
          # loaded by this key. Among others it loads `my`, without which OAuth
          # flows (Hilo) send a redirect URI their provider has not registered.
          default_config = {};

          # Hilo's generated energy meters call utility_meter's setup
          # themselves; unless HA has already set the domain up from here, its
          # later setup wipes their meter data and every meter fails.
          utility_meter = {};

          homeassistant = {
            name = "Home";
            time_zone = "America/Toronto";
          };

          # HTTP server configuration for reverse proxy
          http = {
            server_host = "0.0.0.0";
            server_port = 8123;
            use_x_forwarded_for = true;
            # Trust reverse proxy headers from localhost and Tailscale network
            trusted_proxies = ["127.0.0.1" "100.64.0.0/10"];
          };

          # The living room heat pump (Kanion) is IR-only, behind the "Living
          # room IR" Tuya hub, and Tuya's cloud remote never offers heat for it.
          # Its remote speaks the Midea protocol, so midea_ir builds any
          # mode/temperature/fan frame itself and sends it through the hub.
          climate = [
            {
              platform = "midea_ir";
              name = "Living room heat pump";
              unique_id = "living_room_heat_pump";
              remote = "remote.living_room_ir";
              temperature_sensor = "sensor.living_room_ir_temperature_2";
            }
          ];

          # Fallback presets: codes learned from the physical remote through
          # tuya_local, stored under the remote device "living_room_ac". The
          # heat_21 code was learned with the remote on 22 and sets 22°C:
          #
          #   remote.learn_command  entity_id: remote.living_room_ir
          #                         device: living_room_ac
          #                         command: heat_21   (then heat_18, off)
          #
          # An AC remote sends its whole state on every press, so set the
          # physical remote to the preset first, then press a button that
          # re-sends it (e.g. temperature down then up) while learning.
          "script manual" = let
            send = command: {
              sequence = [
                {
                  action = "remote.send_command";
                  target.entity_id = "remote.living_room_ir";
                  data = {
                    device = "living_room_ac";
                    inherit command;
                  };
                }
              ];
              mode = "queued";
            };
          in {
            living_room_ac_heat_21 = send "heat_21" // {alias = "Living room AC - Heat 21°C";};
            living_room_ac_heat_18 = send "heat_18" // {alias = "Living room AC - Heat 18°C";};
            living_room_ac_off = send "off" // {alias = "Living room AC - Off";};
          };

          # Network quality history: mesh latency to raider, internet latency,
          # internet throughput. Design:
          # docs/superpowers/specs/2026-11-01-network-quality-monitoring-design.md
          #
          # Ping and Speedtest.net are config-flow only, so their entries are
          # added once in the UI (Settings → Devices & services → Add):
          #   Ping  raider.local             mesh latency over the LAN. Not the
          #                                  Tailscale name: that measures the
          #                                  tunnel, not the Deco mesh.
          #   Ping  basestar.bat-boa.ts.net  internet path. basestar's public
          #                                  IP drops ICMP echo (OCI list allows
          #                                  type 3 only).
          #   Ping  1.1.1.1                  neutral reference. If basestar
          #                                  rises and this doesn't, the cause is
          #                                  Tailscale/DERP, not the fiber.
          #   (count 5 each). Ping creates its latency, jitter and loss sensors
          #   disabled: enable them, or nothing is recorded or graphed.
          #   Speedtest.net, then System options → disable "Enable polling for
          #   updates", so only the automation below runs tests (its default is
          #   hourly, ~24 full-bandwidth tests a day).
          #
          # Updating one speedtest entity refreshes the integration's
          # coordinator, so download, upload and ping all update. The entity
          # ID comes from the UI-created entry: renaming it breaks this.
          "automation network" = [
            {
              alias = "Network - Speedtest";
              description = "Run an internet speed test every 4 hours";
              triggers = [
                {
                  trigger = "time_pattern";
                  hours = "/4";
                }
              ];
              actions = [
                {
                  action = "homeassistant.update_entity";
                  target.entity_id = "sensor.speedtest_download";
                }
              ];
              mode = "single";
            }
          ];

          # url_path must contain a hyphen. HA joins filename onto the config
          # dir, and an absolute store path survives that join unchanged.
          lovelace.dashboards.dashboard-network = {
            mode = "yaml";
            title = "Network";
            icon = "mdi:lan";
            show_in_sidebar = true;
            require_admin = false;
            filename = "${networkDashboard}";
          };

          # Allow UI-managed configuration files
          # These files will be created and managed by the Home Assistant UI
          "automation ui" = "!include automations.yaml";
          "scene ui" = "!include scenes.yaml";
          "script ui" = "!include scripts.yaml";
        };
      };
    };
  };
}
