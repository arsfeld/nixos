# Constellation Home Assistant module
#
# This module provides Home Assistant home automation platform with support
# for custom integrations via HACS (Home Assistant Community Store).
#
# Key features:
# - Writable configuration for UI-managed automations and HACS installations
# - Built-in support for ESPHome, Met.no weather, and default integrations
# - Custom components for Tuya Local and Alarmo security system
# - Trusted proxy configuration for reverse proxy integration
# - UI-managed automation, scene, and script files
#
# The module enables configWritable to allow HACS to install custom integrations
# and the UI to modify automation files. Configuration changes made through the
# Home Assistant UI will persist across system rebuilds.
#
# Access:
# - Default port: 8123
# - Should be exposed via constellation.services for reverse proxy access
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.constellation.home-assistant = {
    enable = lib.mkOption {
      type = lib.types.bool;
      description = ''
        Enable Home Assistant home automation platform.
        This sets up Home Assistant with support for HACS custom integrations
        and UI-configurable automations, scenes, and scripts.
      '';
      default = false;
    };
  };

  config = lib.mkIf config.constellation.home-assistant.enable {
    services.home-assistant = {
      enable = true;

      # Allow HACS and UI modifications to persist
      configWritable = true;

      # Core integrations to include
      extraComponents = [
        "default_config" # Includes common integrations (sun, person, zone, etc.)
        "met" # Met.no weather integration
        "esphome" # ESPHome device integration
      ];

      # Custom components from nixpkgs
      customComponents = with pkgs.home-assistant-custom-components; [
        tuya_local # Local control of Tuya devices
        alarmo # Security system integration
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
