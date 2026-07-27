{
  pkgs,
  config,
  ...
}: {
  media.gateway.services.netdata = {
    port = 19999;
    exposeViaTailscale = true;
  };
  media.gateway.services.grafana = {
    port = 3010;
    exposeViaTailscale = true;
    settings = {
      bypassAuth = true;
    };
  };
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

  # Alert delivery. Netdata's stock alarm-notify.sh defaults to email via
  # sendmail, which isn't installed — every alert transition on every streamed
  # node was failing with "Cannot find sendmail command in the system path"
  # and going nowhere but the journal. Route to ntfy instead, matching the
  # publisher pattern used by backrest/image-watch/check-stock.
  #
  # As the stream parent, galactica runs health checks for its children too,
  # so this single config covers basestar/pegasus/raider alerts as well.
  sops.secrets."ntfy-publisher-env" = {
    restartUnits = ["netdata.service"];
  };

  # curl is resolved by alarm-notify.sh at runtime via `command -v curl`.
  systemd.services.netdata = {
    path = [pkgs.curl];
    serviceConfig.EnvironmentFile = config.sops.secrets."ntfy-publisher-env".path;
  };

  services.netdata.configDir."health_alarm_notify.conf" = pkgs.writeText "health_alarm_notify.conf" ''
    SEND_EMAIL="NO"
    SEND_CUSTOM="YES"
    DEFAULT_RECIPIENT_CUSTOM="sysadmin"

    # Args from alarm-notify.sh: 1=to 2=host 3=unique_id 4=alarm_id 5=event_id
    # 6=when 7=name 8=chart 9=status 10=old_status 11=value 12=old_value
    # 13=src 14=duration 15=non_clear_duration 16=units 17=info
    custom_sender() {
      local priority tags

      case "''${status}" in
        CRITICAL) priority="urgent"; tags="rotating_light" ;;
        WARNING)  priority="high";   tags="warning" ;;
        CLEAR)    priority="low";    tags="white_check_mark" ;;
        *)        priority="default"; tags="information_source" ;;
      esac

      curl -fsS --max-time 10 -X POST \
        -H "Authorization: Basic $NTFY_BASIC_AUTH_B64" \
        -H "Title: ''${status}: ''${name} on ''${host}" \
        -H "Priority: $priority" \
        -H "Tags: $tags" \
        -d "''${chart} = ''${value_string}

    ''${info}" \
        https://ntfy.arsfeld.one/netdata >/dev/null || true
    }
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
