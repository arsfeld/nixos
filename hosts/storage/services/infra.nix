{pkgs, ...}: {
  services.netdata = {
    enable = true;
    package = pkgs.netdata.override {
      withCloudUi = true;
    };
    config = {
      global = {
        "memory mode" = "ram";
        "debug log" = "none";
        "access log" = "none";
        "error log" = "syslog";
      };
      plugins = {
        "apps" = "no";
        "go.d" = "no"; # Disable go.d plugin to stop podman API polling
      };
    };
  };

  services.netdata.configDir."stream.conf" = pkgs.writeText "stream.conf" ''
    [387acf23-8aff-4934-bc3a-1c2950e9df58]
      enabled = yes
      enable compression = yes
      default memory mode = dbengine # a good default
      health enabled by default = auto
  '';

  services.redis.servers.blocky.slaveOf = {
    ip = "100.66.38.77";
    port = 6378;
  };

  services.scrutiny = {
    enable = true;
    #collector.schedule = "0 0 * * 7";
    collector.enable = true;
    settings.web.listen.port = 9998;
  };

  # Beszel monitoring configuration moved to constellation.beszel module
  constellation.beszel = {
    enable = false; # Disabled to reduce CPU usage from podman polling
    hub.enable = true;
    agent.enable = true;
  };
}
