# Network tools: Omada Controller, Termix, Transfer.sh, Cloudreve
{
  config,
  lib,
  self,
  ...
}: let
  cfg = config.constellation.networkTools;
  mkService = import "${self}/modules/media/__mkService.nix" {inherit lib;};
  vars = config.media.config;
in {
  options.constellation.networkTools.enable = lib.mkEnableOption "network tools (Omada, Termix, Transfer, Cloudreve)";

  config = lib.mkIf cfg.enable (lib.mkMerge [
    (mkService "omada" {
      port = 8043;
      image = "mbentley/omada-controller:latest";
      container = {
        exposePort = 8043;
        configDir = null;
        network = "host";
        volumes = [
          "${vars.configDir}/omada/data:/opt/tplink/EAPController/data"
          "${vars.configDir}/omada/logs:/opt/tplink/EAPController/logs"
        ];
        environment = {
          TZ = "America/New_York";
          MANAGE_HTTP_PORT = "8088";
          MANAGE_HTTPS_PORT = "8043";
          PORTAL_HTTPS_PORT = "8843";
        };
        extraOptions = [
          "--ulimit"
          "nofile=4096:8192"
          "--stop-timeout"
          "60"
        ];
      };
      bypassAuth = true;
      insecureTls = true;
    })

    (mkService "termix" {
      port = 8080;
      image = "ghcr.io/lukegus/termix:latest";
      container = {};
      bypassAuth = true;
    })

    (mkService "transfer" {
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
    })

    (mkService "cloud" {
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
    })
  ]);
}
