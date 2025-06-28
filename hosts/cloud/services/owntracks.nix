{
  config,
  pkgs,
  ...
}: {
  # Install and configure owntracks-recorder with podman (simpler than OCI-containers)
  virtualisation.podman.enable = true;
  
  # Add the systemd services for owntracks-recorder and owntracks-frontend
  systemd.services.owntracks-recorder = {
    description = "OwnTracks Recorder";
    after = ["network.target" "mosquitto.service"];
    requires = ["mosquitto.service"];
    wantedBy = ["multi-user.target"];
    
    serviceConfig = {
      ExecStartPre = [
        "${pkgs.podman}/bin/podman pull owntracks/recorder:latest"
        "-${pkgs.podman}/bin/podman rm -f owntracks-recorder"
      ];
      ExecStart = ''
        ${pkgs.podman}/bin/podman run --rm --name owntracks-recorder \
          -p 8083:8083 \
          -v /var/lib/owntracks/config:/config \
          -v /var/lib/owntracks/store:/store \
          -e OTR_HTTPHOST=0.0.0.0 \
          -e OTR_TOPICS=owntracks/# \
          -e OTR_HOST=host.containers.internal \
          -e OTR_PORT=1883 \
          owntracks/recorder:latest
      '';
      ExecStop = "${pkgs.podman}/bin/podman stop -t 10 owntracks-recorder";
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStartSec = "5min";
      TimeoutStopSec = "1min";
    };
  };
  
  systemd.services.owntracks-frontend = {
    description = "OwnTracks Frontend";
    after = ["network.target" "owntracks-recorder.service"];
    requires = ["owntracks-recorder.service"];
    wantedBy = ["multi-user.target"];
    
    serviceConfig = {
      ExecStartPre = [
        "${pkgs.podman}/bin/podman pull owntracks/frontend:latest"
        "-${pkgs.podman}/bin/podman rm -f owntracks-frontend"
      ];
      ExecStart = ''
        ${pkgs.podman}/bin/podman run --rm --name owntracks-frontend \
          -p 8084:80 \
          -e SERVER_HOST=localhost \
          -e SERVER_PORT=8083 \
          owntracks/frontend:latest
      '';
      ExecStop = "${pkgs.podman}/bin/podman stop -t 10 owntracks-frontend";
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStartSec = "5min";
      TimeoutStopSec = "1min";
    };
  };
  
  # Create necessary directories for OwnTracks
  system.activationScripts.owntracks-dirs = {
    text = ''
      mkdir -p /var/lib/owntracks/config
      mkdir -p /var/lib/owntracks/store
    '';
    deps = [];
  };
  
  # Open firewall ports for OwnTracks services
  networking.firewall.allowedTCPPorts = [
    8083  # OwnTracks Recorder HTTP API
    8084  # OwnTracks Frontend
  ];
}