# Constellation Home Assistant module
#
# This module provides Home Assistant home automation platform with support
# for custom integrations via HACS (Home Assistant Community Store).
#
# Key features:
# - Writable configuration for UI-managed automations and HACS installations
# - Built-in support for ESPHome, Met.no weather, TP-Link Kasa, and default integrations
# - Custom components for Tuya Local, Alarmo, Hilo, Eufy Security (eufy-sdk)
#   Tuya IR air conditioners, and Midea-protocol IR air conditioners
# - Trusted proxy configuration for reverse proxy integration
# - UI-managed automation, scene, and script files
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
{pkgs, ...}: {
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
        "wake_on_lan" # Wake on LAN
      ];

      # Custom components from nixpkgs, plus the ones packaged in ./packages
      customComponents = with pkgs.home-assistant-custom-components; [
        tuya_local # Local control of Tuya devices
        alarmo # Security system integration
        pkgs.home-assistant-hilo # Hydro-Québec Hilo
        pkgs.home-assistant-eufy-sdk # Eufy Security, via the eufy-sdk-bridge container
        pkgs.home-assistant-tuya-smart-ir-ac # IR air conditioners behind Tuya Smart IR hubs
        pkgs.home-assistant-midea-ir # Midea-protocol IR ACs, encoded locally
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

        # Hilo challenges. sensor.defi_hilo is "reduction" while the challenge
        # is live; any later state (recovery, completed, off) ends it.
        "automation manual" = let
          heatTo = temperature: {
            action = "climate.set_temperature";
            target.entity_id = "climate.living_room_heat_pump";
            data = {
              hvac_mode = "heat";
              inherit temperature;
            };
          };
        in [
          {
            alias = "Hilo Challenge - Lower Heat Pump";
            description = "Set the living room heat pump to 18°C during Hilo challenges";
            triggers = [
              {
                trigger = "state";
                entity_id = "sensor.defi_hilo";
                to = "reduction";
              }
            ];
            actions = [(heatTo 18)];
            mode = "single";
          }
          {
            alias = "Hilo Challenge End - Restore Heat Pump";
            description = "Restore the living room heat pump to 21°C after a Hilo challenge";
            triggers = [
              {
                trigger = "state";
                entity_id = "sensor.defi_hilo";
                from = "reduction";
              }
            ];
            actions = [(heatTo 21)];
            mode = "single";
          }
        ];

        # Allow UI-managed configuration files
        # These files will be created and managed by the Home Assistant UI
        "automation ui" = "!include automations.yaml";
        "scene ui" = "!include scenes.yaml";
        "script ui" = "!include scripts.yaml";
      };
    };
  };
}
