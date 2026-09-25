# Constellation Home Assistant module
#
# This module provides Home Assistant home automation platform with support
# for custom integrations via HACS (Home Assistant Community Store).
#
# Key features:
# - Writable configuration for UI-managed automations and HACS installations
# - Built-in support for ESPHome, Met.no weather, TP-Link Kasa, and default integrations
# - Custom components for Tuya Local, Alarmo, Hilo, Eufy Security (eufy-sdk)
#   and Tuya IR air conditioners
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

        # Declarative automations for Hilo challenge response
        # NOTE: Entity names (climate.tuya_heat_pump, binary_sensor.hilo_challenge)
        # need to be updated based on actual device names after Tuya and Hilo
        # integrations are configured in the Home Assistant UI.
        "automation manual" = [
          {
            alias = "Hilo Challenge - Lower Heat Pump";
            description = "Lower Tuya heat pump to 18°C during Hilo challenges";
            trigger = [
              {
                platform = "state";
                entity_id = "binary_sensor.hilo_challenge";
                to = "on";
              }
            ];
            action = [
              {
                service = "climate.set_temperature";
                target.entity_id = "climate.tuya_heat_pump"; # Adjust to match actual Tuya device entity
                data.temperature = 18;
              }
            ];
            mode = "single";
          }
          {
            alias = "Hilo Challenge End - Restore Heat Pump";
            description = "Restore Tuya heat pump to 21°C after Hilo challenge";
            trigger = [
              {
                platform = "state";
                entity_id = "binary_sensor.hilo_challenge";
                from = "on";
                to = "off";
              }
            ];
            action = [
              {
                service = "climate.set_temperature";
                target.entity_id = "climate.tuya_heat_pump"; # Adjust to match actual Tuya device entity
                data.temperature = 21;
              }
            ];
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
