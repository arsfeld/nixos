# Mydia metadata-relay service
#
# This service provides centralized metadata caching and API aggregation for Mydia.
# It acts as a caching layer for TMDB and TVDB APIs to reduce API calls and improve
# performance across multiple Mydia instances.
#
# Key features:
# - Redis-backed caching for metadata
# - API aggregation for TMDB and TVDB
# - Reduces external API calls and rate limiting issues
# - Dedicated domain configuration (metadata-relay.arsfeld.dev)
{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.services.metadata-relay;
  services = config.media.gateway.services;
in {
  options.services.metadata-relay = {
    enable = mkOption {
      type = types.bool;
      description = ''
        Enable the Mydia metadata-relay service.
        This provides centralized metadata caching for Mydia instances.
      '';
      default = false;
    };

    domain = mkOption {
      type = types.str;
      default = "metadata-relay.arsfeld.dev";
      description = ''
        The domain name where the metadata-relay service will be accessible.
        This domain will be configured in Caddy with ACME certificates.
      '';
      example = "metadata-relay.example.com";
    };
  };

  config = mkIf cfg.enable {
    # Ensure Caddy is enabled
    services.caddy.enable = true;

    # Configure Caddy virtual host for metadata-relay
    services.caddy.virtualHosts."${cfg.domain}" = {
      useACMEHost = "arsfeld.dev"; # Use existing wildcard certificate
      extraConfig = ''
        # Reverse proxy to metadata-relay container
        reverse_proxy localhost:${toString services.metadata-relay.port}
      '';
    };
  };
}
