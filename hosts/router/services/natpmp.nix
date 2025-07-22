{
  config,
  lib,
  pkgs,
  ...
}:
with lib; {
  imports = [
    ../../../packages/natpmp-server/module.nix
  ];

  services.natpmp-server = {
    enable = true;

    # Router interfaces
    externalInterface = config.router.interfaces.wan; # Use configured WAN interface
    listenInterface = "br-lan"; # LAN bridge interface

    # Security settings
    maxMappingsPerClient = 50;
    defaultLifetime = 3600; # 1 hour
    maxLifetime = 86400; # 24 hours

    # Port ranges - allow standard unprivileged ports
    allowedPortRanges = [
      {
        from = 1024;
        to = 65535;
      }
    ];

    # Use custom nftables chains to avoid conflicts
    nftables = {
      natTable = "nat";
      natChain = "NATPMP_DNAT";
      filterTable = "filter";
      filterChain = "NATPMP_FORWARD";
    };

    # Enable Prometheus metrics
    metricsPort = 9333; # Use a different port to avoid conflicts
  };

  # Create a wrapper script for nftables reload that also restarts NAT-PMP
  environment.etc."nftables-reload-wrapper" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      # Reload nftables
      ${pkgs.systemd}/bin/systemctl reload nftables.service
      # Give nftables time to settle
      sleep 1
      # Restart NAT-PMP to recreate its rules
      if ${pkgs.systemd}/bin/systemctl is-active --quiet natpmp-server.service; then
        echo "Restarting NAT-PMP server to recreate rules..."
        ${pkgs.systemd}/bin/systemctl restart natpmp-server.service
      fi
    '';
  };

  # Add an alias for convenience
  environment.shellAliases = {
    "nftables-reload" = "/etc/nftables-reload-wrapper";
  };
}
