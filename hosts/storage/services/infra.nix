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

  # Disable swap memory alerts on development machines
  # Raider frequently uses swap during heavy workloads (gaming, builds, etc.)
  services.netdata.configDir."health.d/swap.conf" = pkgs.writeText "swap.conf" ''
    # Disable swap alerts on development hosts
       alarm: used_swap
          on: mem.swap
    host labels: environment = !development *
       calc: $used * 100 / ($used + $free)
       units: %
       every: 10s
        warn: $this > (($status >= $WARNING)  ? (70) : (80))
        crit: $this > (($status == $CRITICAL) ? (80) : (90))
       delay: up 30s down 5m multiplier 1.5 max 1h
        info: swap memory utilization
          to: silent
  '';

  # Exclude development hosts from Docker container health alerts
  # Raider has environment=development label and its containers are frequently unstable
  services.netdata.configDir."health.d/docker.conf" = pkgs.writeText "docker.conf" ''
       template: docker_container_unhealthy
             on: docker.container_health_status
    host labels: environment = !development *
          class: Errors
           type: Containers
      component: Docker
         lookup: average -1m unaligned of unhealthy
          units: status
          every: 10s
           crit: 0

       template: docker_container_health_status
             on: docker.container_health_status
    host labels: environment = !development *
          class: Errors
           type: Containers
      component: Docker
         lookup: average -1m unaligned
          units: status
          every: 10s
           crit: 0
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

  # Beszel monitoring - removed (no longer used)
}
