# Constellation Netdata client module
#
# This module configures Netdata as a streaming client that sends metrics to
# a central Netdata parent node. It's designed for lightweight metric collection
# on satellite hosts without local storage or web interface.
#
# Key features:
# - Streaming-only mode (no local data retention)
# - Minimal resource usage (memory mode: none)
# - Web interface disabled to reduce attack surface
# - Automatic streaming to the storage host parent node
# - Real-time metrics collection and forwarding
#
# This configuration is ideal for edge nodes, embedded devices, and systems
# where you want monitoring without the overhead of local metric storage.
# All metrics are streamed to the central storage host for aggregation and
# visualization.
{
  pkgs,
  lib,
  config,
  ...
}: {
  options.constellation.netdataClient = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable Netdata in streaming client mode.
        This collects system metrics and streams them to the central
        Netdata parent node without local storage or web interface.
      '';
    };
  };

  config = lib.mkIf config.constellation.netdataClient.enable {
    services.netdata = {
      enable = true;

      configDir."stream.conf" = pkgs.writeText "stream.conf" ''
        [stream]
          enabled = yes
          destination = storage:19999
          api key = 387acf23-8aff-4934-bc3a-1c2950e9df58
      '';

      config = {
        global = {"memory mode" = "none";};
        web = {
          mode = "none";
          "accept a streaming request every seconds" = 0;
        };
      };
    };
  };
}
