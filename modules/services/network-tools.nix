# Network tools: Termix, Transfer.sh, Cloudreve
{
  config,
  lib,
  ...
}: let
  cfg = config.constellation.networkTools;
  vars = config.media.config;
in {
  options.constellation.networkTools.enable = lib.mkEnableOption "network tools (Termix, Transfer, Cloudreve)";

  config = lib.mkIf cfg.enable {
    media.services.termix = {
      port = 8080;
      image = "ghcr.io/lukegus/termix:latest";
      container = {};
      bypassAuth = true;
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
      bypassAuth = true;
    };

    media.services.cloud = {
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
