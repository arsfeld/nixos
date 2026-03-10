{
  self,
  config,
  pkgs,
  ...
}: let
  dataDir = "/var/lib/finance-tracker";
  financeTrackerScript = pkgs.writeShellApplication {
    name = "finance-tracker";
    runtimeInputs = [pkgs.podman];
    text = ''
      exec podman run \
        --rm \
        --pull newer \
        --volume "${dataDir}:/config" \
        --env DATA_DIR=/config \
        --env FILTER_CONFIG_PATH=/config/filter-config.yaml \
        --env-file "${config.age.secrets."finance-tracker-env".path}" \
        ghcr.io/arsfeld/finance-tracker:latest ./finance-tracker "$@"
    '';
  };
in {
  media.gateway.services.home = {
    port = 8085;
    exposeViaTailscale = true;
    settings.funnel = true;
  };
  media.gateway.services.www = {
    port = 8085;
    exposeViaTailscale = true;
  };

  age.secrets."finance-tracker-env" = {
    file = "${self}/secrets/finance-tracker-env.age";
  };

  # Create the finance-tracker script
  environment.systemPackages = [
    financeTrackerScript
  ];

  # Ensure data directory exists
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0755 root root -"
  ];

  # Systemd service and timer for finance-tracker
  systemd.services.finance-tracker = {
    description = "Finance Tracker Service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${financeTrackerScript}/bin/finance-tracker";
    };
  };

  systemd.timers.finance-tracker = {
    description = "Finance Tracker Timer";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-1/2 17:00:00";
      Persistent = true; # Run if missed
      RandomizedDelaySec = "1h"; # Random delay up to 1 hour
    };
  };
}
