# iSponsorBlockTV service - Skip sponsored segments on YouTube for Apple TV
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.isponsorblock;
in {
  options.services.isponsorblock = {
    enable = lib.mkEnableOption "iSponsorBlockTV - Skip sponsored segments on YouTube for Apple TV";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8001;
      description = "Port for iSponsorBlockTV API server";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/isponsorblock";
      description = "Data directory for iSponsorBlockTV";
    };

    skipCategories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["sponsor"];
      description = ''
        Categories of segments to skip.
        Options: sponsor, selfpromo, interaction, intro, outro, preview, music_offtopic, filler
      '';
    };

    channelWhitelist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "YouTube channel IDs to never skip segments for";
    };

    muteAds = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Mute ads instead of skipping them";
    };

    skipAdsDelay = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Delay in seconds before skipping ads";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create data directory
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
      "d ${cfg.dataDir}/config 0755 root root -"
      "d ${cfg.dataDir}/cache 0755 root root -"
    ];

    # iSponsorBlockTV container
    virtualisation.oci-containers.containers.isponsorblock = {
      image = "ghcr.io/dmunozv04/isponsorblocktv:latest";
      environment = {
        SBTVPORT = toString cfg.port;
        SKIP_CATEGORIES = lib.concatStringsSep "," cfg.skipCategories;
        CHANNEL_WHITELIST = lib.concatStringsSep "," cfg.channelWhitelist;
        MUTE_ADS =
          if cfg.muteAds
          then "true"
          else "false";
        SKIP_ADS_DELAY = toString cfg.skipAdsDelay;
      };
      volumes = [
        "${cfg.dataDir}/config:/app/data"
        "${cfg.dataDir}/cache:/app/cache"
      ];
      ports = [
        "${toString cfg.port}:${toString cfg.port}"
      ];
    };

    # Caddy reverse proxy configuration
    services.caddy.virtualHosts."isponsorblock.arsfeld.one" = {
      useACMEHost = "arsfeld.one";
      extraConfig = ''
        encode zstd gzip

        header {
          X-Frame-Options "SAMEORIGIN"
          X-Content-Type-Options "nosniff"
          X-XSS-Protection "1; mode=block"
        }

        reverse_proxy localhost:${toString cfg.port} {
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }
      '';
    };

    # Open firewall port for local network access
    networking.firewall.allowedTCPPorts = [cfg.port];
  };
}
