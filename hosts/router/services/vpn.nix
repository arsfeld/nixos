{
  config,
  lib,
  pkgs,
  ...
}: let
  netConfig = config.router.network;
  network = "${netConfig.prefix}.0/${toString netConfig.cidr}";
in {
  # Tailscale VPN
  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = "server"; # Enable subnet routing
  };

  # Advertise the LAN subnet to Tailscale
  systemd.services.tailscale-subnet-router = {
    description = "Advertise subnet routes to Tailscale";
    after = ["tailscale.service" "network-online.target"];
    wants = ["tailscale.service" "network-online.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale up --ssh --advertise-routes=${network} --accept-routes";
    };
  };
}
