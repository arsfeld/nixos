# Network tools: Termix, Transfer.sh, Cloudreve
{
  config,
  lib,
  ...
}: let
  vars = config.media.config;
in {
  config = {
    media.services.termix = {
      # Probe-verified (hardened run failed, passes with these).
      # CHOWN: /entrypoint.sh runs 'chown -R node:node /app/data ...'.
      # DAC_OVERRIDE: write /app/data owned by media.
      # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
      # SETUID, SETGID: /entrypoint.sh runs 'usermod -o -u $PUID node' then 'exec gosu node:node' (failed 'failed switching to node:node' without them).
      container.hardening.caps = ["CHOWN" "DAC_OVERRIDE" "FOWNER" "SETUID" "SETGID"];
      port = 8080;
      image = "ghcr.io/lukegus/termix:latest";
      container = {};
    };

    media.services.transfer = {
      port = 8080;
      image = "dutchcoders/transfer.sh:latest";
      container = {
        exposePort = 8281;
        configDir = null;
        volumes = [
          "${vars.storageDir}/transfer:/tmp/transfer.sh"
        ];
        environment = {
          PROVIDER = "local";
          BASEDIR = "/tmp/transfer.sh";
          PURGE_DAYS = "14";
          MAX_UPLOAD_SIZE = "5368709120";
        };
      };
    };

    media.services.cloud = {
      # Probe-verified: root process writes /cloudreve/data/conf.ini owned by media (5000) and failed with EACCES without caps.
      # DAC_OVERRIDE: write dirs/files owned by another uid.
      # FOWNER: precautionary alongside DAC_OVERRIDE (not individually shown necessary).
      container.hardening.caps = ["DAC_OVERRIDE" "FOWNER"];
      port = 5212;
      image = "cloudreve/cloudreve:latest";
      container = {
        exposePort = 5212;
        configDir = null;
        volumes = [
          "${vars.configDir}/cloudreve:/cloudreve/data"
          "${vars.storageDir}/cloudreve:/cloudreve/uploads"
        ];
      };
      bypassAuth = true;
    };
  };
}
