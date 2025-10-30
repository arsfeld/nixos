{
  config,
  self,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.qbittorrent-vpn;
  vars = config.media.config;

  # Network namespace and veth configuration
  namespace = "wg-qbittorrent";
  vethHost = "veth-qbt-host";
  vethNS = "veth-qbt-ns";
  hostIP = "10.200.200.1/24";
  nsIP = "10.200.200.2/24";
  wgInterface = "wg-airvpn";
in {
  options.services.qbittorrent-vpn = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable qBittorrent with WireGuard VPN in isolated network namespace";
    };
  };

  config = lib.mkIf cfg.enable {
    # Load AirVPN WireGuard secret
    age.secrets."airvpn-wireguard" = {
      file = "${self}/secrets/airvpn-wireguard.age";
      mode = "400";
    };

    # Custom systemd service to bring up WireGuard in namespace
    systemd.services.wireguard-vpn-namespace = {
      description = "WireGuard VPN in isolated namespace for qBittorrent";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.wireguard-tools pkgs.iproute2];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -e

        # Create network namespace
        ${pkgs.iproute2}/bin/ip netns add ${namespace} || true

        # Enable loopback in namespace
        ${pkgs.iproute2}/bin/ip netns exec ${namespace} ${pkgs.iproute2}/bin/ip link set lo up

        # Create veth pair linking host to namespace
        ${pkgs.iproute2}/bin/ip link add ${vethHost} type veth peer name ${vethNS} || true

        # Move namespace end of veth into the namespace
        ${pkgs.iproute2}/bin/ip link set ${vethNS} netns ${namespace} || true

        # Configure host end of veth
        ${pkgs.iproute2}/bin/ip addr add ${hostIP} dev ${vethHost} || true
        ${pkgs.iproute2}/bin/ip link set ${vethHost} up

        # Configure namespace end of veth
        ${pkgs.iproute2}/bin/ip netns exec ${namespace} ${pkgs.iproute2}/bin/ip addr add ${nsIP} dev ${vethNS}
        ${pkgs.iproute2}/bin/ip netns exec ${namespace} ${pkgs.iproute2}/bin/ip link set ${vethNS} up

        # Add routes in namespace for accessing host network through veth
        # Local network (10.0.0.0/8) - for Tailscale and local LAN
        ${pkgs.iproute2}/bin/ip netns exec ${namespace} ${pkgs.iproute2}/bin/ip route add 10.0.0.0/8 via 10.200.200.1 dev ${vethNS} || true
        # Tailscale CGNAT range
        ${pkgs.iproute2}/bin/ip netns exec ${namespace} ${pkgs.iproute2}/bin/ip route add 100.64.0.0/10 via 10.200.200.1 dev ${vethNS} || true

        # Bring up WireGuard interface in namespace using wg-quick
        ${pkgs.iproute2}/bin/ip netns exec ${namespace} ${pkgs.wireguard-tools}/bin/wg-quick up ${config.age.secrets.airvpn-wireguard.path}
      '';

      preStop = ''
        # Bring down WireGuard
        ${pkgs.iproute2}/bin/ip netns exec ${namespace} ${pkgs.wireguard-tools}/bin/wg-quick down ${config.age.secrets.airvpn-wireguard.path} || true

        # Remove veth pair
        ${pkgs.iproute2}/bin/ip link del ${vethHost} || true

        # Remove namespace
        ${pkgs.iproute2}/bin/ip netns del ${namespace} || true
      '';
    };

    # qBittorrent service running in VPN namespace
    systemd.services.qbittorrent-nox = {
      description = "qBittorrent-nox service in VPN namespace";
      after = ["wireguard-vpn-namespace.service"];
      requires = ["wireguard-vpn-namespace.service"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        User = vars.user;
        Group = vars.group;

        # Run in VPN namespace
        NetworkNamespacePath = "/var/run/netns/${namespace}";

        # Bind qBittorrent to all interfaces in namespace (WebUI accessible via veth)
        ExecStart = "${pkgs.qbittorrent-nox}/bin/qbittorrent-nox --webui-port=8080";

        Restart = "on-failure";
        RestartSec = "5s";

        # Security hardening
        PrivateTmp = true;
        NoNewPrivileges = true;

        # State directory for qBittorrent config and session data
        StateDirectory = "qbittorrent";
        StateDirectoryMode = "0750";
      };

      environment = {
        # qBittorrent data directory
        QBT_PROFILE = "/var/lib/qbittorrent";
        HOME = "/var/lib/qbittorrent";
      };
    };

    # Open WebUI port on host firewall (for access via veth)
    networking.firewall.allowedTCPPorts = [8080];
  };
}
