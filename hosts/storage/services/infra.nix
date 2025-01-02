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

  users.users.beszel = {
    group = "beszel";
    home = "/var/lib/beszel";
    isSystemUser = true;
    createHome = true;
  };

  users.groups.beszel.name = "beszel";

  systemd.services.beszel-hub = {
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      User = "beszel";
      ExecStart = "${pkgs.beszel}/bin/beszel-hub serve --http 0.0.0.0:8090";
      WorkingDirectory = "/var/lib/beszel";
    };
  };

  users.users.beszel-agent = {
    group = "beszel-agent";
    home = "/var/lib/beszel-agent";
    isSystemUser = true;
    createHome = true;
  };

  users.groups.beszel-agent.name = "beszel-agent";

  systemd.services.beszel-agent = {
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    serviceConfig = {
      Environment = [
        "PORT=45876"
        "KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGKIjUSMdRqYMmZopjoXBVbEW2SpjE4mxrPclsnQCvW9'"
      ];
      User = "beszel-agent";
      ExecStart = "${pkgs.beszel}/bin/beszel-agent";
      WorkingDirectory = "/var/lib/beszel-agent";
    };
  };
}
