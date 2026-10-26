# Home and utility apps: Audiobookshelf, Stirling PDF, Actual Budget
{
  config,
  lib,
  ...
}: let
  vars = config.media.config;
in {
  config = {
    media.services.audiobookshelf = {
      # Probe-verified: root process failed with EACCES creating /metadata/streams and listening without caps.
      # DAC_OVERRIDE: write /config and /metadata owned by media.
      # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
      # NET_BIND_SERVICE: listens on port 80 in-container (listen EACCES without it).
      container.hardening.caps = ["DAC_OVERRIDE" "FOWNER" "NET_BIND_SERVICE"];
      port = 80;
      image = "ghcr.io/advplyr/audiobookshelf:latest";
      container = {
        exposePort = 13378;
        configDir = null;
        volumes = [
          "${vars.configDir}/audiobookshelf/config:/config"
          "${vars.configDir}/audiobookshelf/metadata:/metadata"
          "${vars.dataDir}/media/audiobooks:/audiobooks"
          "${vars.dataDir}/media/podcasts:/podcasts"
        ];
        extraOptions = [
          "--label"
          "io.containers.autoupdate=image"
        ];
      };
      bypassAuth = true;
      tailscaleExposed = true;
    };

    media.services.stirling = {
      # Verdict: FAIL with no caps (hardened run logged mkdir EACCES on /configs/cache and /configs/heap_dumps), then PASS with the set below.
      # DAC_OVERRIDE: the only cap with direct evidence (mkdir permission denied on /configs/cache and /configs/heap_dumps, owned by media).
      # CHOWN, FOWNER, SETUID, SETGID: precautionary; they were added together with DAC_OVERRIDE and never tested individually (no chown or setuid error was observed).
      container.hardening.caps = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID"];
      port = 8080;
      image = "frooodle/s-pdf:latest";
      container = {
        exposePort = 9284;
        configDir = "/configs";
      };
    };

    media.services.actual = {
      # Probe-verified: root process writes /data owned by media (5000) and failed with EACCES without caps.
      # DAC_OVERRIDE: write dirs/files owned by another uid.
      # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
      container.hardening.caps = ["DAC_OVERRIDE" "FOWNER"];
      port = 5006;
      image = "ghcr.io/actualbudget/actual-server:latest";
      container = {
        volumes = [
          "${vars.configDir}/actual:/data"
        ];
      };
      bypassAuth = true;
    };
  };
}
