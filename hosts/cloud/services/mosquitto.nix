{
  config,
  lib,
  ...
}: {
  # Enable Mosquitto MQTT broker
  services.mosquitto = {
    enable = true;
    
    # Configure MQTT listeners
    listeners = [
      {
        # Standard MQTT on port 1883
        address = "0.0.0.0";
        port = 1883;
        settings.allow_anonymous = true;
      }
    ];
    
    # Persistence settings
    persistence = true;
  };
  
  # Open firewall ports
  networking.firewall.allowedTCPPorts = [
    1883  # MQTT
  ];
}