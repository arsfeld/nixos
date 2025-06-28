{
  ...
}: {
  # Enable RustDesk server with both signal and relay components
  services.rustdesk-server = {
    enable = true;
    openFirewall = true;
    
    # Signal server (ID registration and heartbeat)
    signal = {
      enable = true;
      relayHosts = [ "127.0.0.1" ];  # Point to local relay server
      extraArgs = [
        "-k" "_"  # Disable key verification (for easier setup)
      ];
    };
    
    # Relay server (for connections that can't go direct)
    relay = {
      enable = true;
      extraArgs = [
        "-k" "_"  # Disable key verification (for easier setup)
      ];
    };
  };
}
