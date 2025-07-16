{
  config,
  lib,
  pkgs,
  ...
}: let
  netConfig = config.router.network;
  network = "${netConfig.prefix}.0/${toString netConfig.cidr}";
in {
  # UPnP/NAT-PMP server
  services.miniupnpd = {
    enable = true;
    externalInterface = config.router.interfaces.wan;
    internalIPs = ["br-lan"];
    natpmp = true;
    upnp = true;
    appendConfig = ''
      # Allow port forwarding
      allow 1024-65535 ${network} 1024-65535
      # Enable secure mode to allow private IPs (for testing)
      secure_mode=no
      # Ensure chains are created
      upnp_forward_chain=MINIUPNPD
      upnp_nat_chain=MINIUPNPD
      # Enable detailed logging for monitoring
      enable_upnp=yes
      enable_natpmp=yes
      # Write lease file for monitoring
      lease_file=/var/lib/miniupnpd/upnp.leases
      # Enable port for status queries
      presentation_url=http://192.168.1.1:2189/
    '';
  };

  # Make sure miniupnpd starts after the bridge is configured
  systemd.services.miniupnpd = {
    after = ["network-online.target" "nftables.service"];
    wants = ["network-online.target"];
    serviceConfig.Restart = "on-failure";
    serviceConfig.RestartSec = "5s";
  };
}
