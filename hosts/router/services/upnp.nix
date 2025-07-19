{
  config,
  lib,
  pkgs,
  ...
}: let
  netConfig = config.router.network;
  network = "${netConfig.prefix}.0/${toString netConfig.cidr}";
  routerIp = "${netConfig.prefix}.1";
in {
  # UPnP/NAT-PMP server - disabled in favor of custom natpmp-server
  services.miniupnpd = {
    enable = false;
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
      presentation_url=http://${routerIp}:2189/
      # Force HTTP port
      http_port=2189
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
