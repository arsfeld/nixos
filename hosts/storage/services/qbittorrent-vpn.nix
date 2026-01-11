{
  config,
  self,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.qbittorrent-vpn;
  vars = config.media.config;
in {
  options.services.qbittorrent-vpn = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable qBittorrent with WireGuard VPN confinement";
    };
  };

  config = lib.mkIf cfg.enable {
    # Load AirVPN WireGuard secret
    age.secrets."airvpn-wireguard" = {
      file = "${self}/secrets/airvpn-wireguard.age";
      mode = "400";
    };

    # Override qbittorrent gateway config to use namespace IP instead of localhost
    # This is necessary because storage's Caddy needs to proxy to the VPN namespace
    # (192.168.15.1) rather than localhost (which doesn't go through DNAT rules)
    media.gateway.services.qbittorrent.host = lib.mkForce "192.168.15.1";

    # VPN namespace configuration using VPN-Confinement
    vpnNamespaces.wg = {
      enable = true;
      wireguardConfigFile = config.age.secrets.airvpn-wireguard.path;

      # Allow access from Tailscale network, Podman network, and local LAN
      accessibleFrom = [
        "100.64.0.0/10" # Tailscale CGNAT range
        "10.0.0.0/8" # Local networks (includes Podman 10.88.0.0/16)
        "192.168.0.0/16" # Additional local networks
      ];

      # Map ports from host to namespace for WebUI access
      portMappings = [
        {
          from = 8080;
          to = 8080;
        }
        {
          from = 9091;
          to = 9091;
        }
      ];

      # Do NOT expose ports through VPN for security
      openVPNPorts = [];
    };

    # Configure qBittorrent service with VPN confinement
    systemd.services.qbittorrent-nox = {
      description = "qBittorrent-nox service confined to VPN";
      wantedBy = ["multi-user.target"];

      # VPN confinement configuration
      vpnConfinement = {
        enable = true;
        vpnNamespace = "wg";
      };

      serviceConfig = {
        Type = "simple";
        User = vars.user;
        Group = vars.group;

        # Bind qBittorrent WebUI to all interfaces
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

    # Override wg-up script to remove ping check which fails on some AirVPN servers (e.g. ca3)
    systemd.services.wg.serviceConfig.ExecStart = let
      script = pkgs.writeShellScript "wg-up" ''
        set -o errexit
        set -o nounset
        set -o pipefail

        export PATH="${lib.makeBinPath [
          pkgs.bash
          pkgs.iproute2
          pkgs.iptables
          pkgs.wireguard-tools
          pkgs.gnugrep
          pkgs.coreutils
        ]}:$PATH"

        ip netns add wg

        # Set up netns firewall
        ip netns exec wg iptables -P INPUT DROP
        ip netns exec wg ip6tables -P INPUT DROP

        ip netns exec wg iptables -P FORWARD DROP
        ip netns exec wg ip6tables -P FORWARD DROP

        ip netns exec wg iptables -A INPUT -i lo -j ACCEPT
        ip netns exec wg ip6tables -A INPUT -i lo -j ACCEPT

        ip netns exec wg iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
        ip netns exec wg ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP

        ip netns exec wg iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        ip netns exec wg ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        ip netns exec wg ip6tables -A INPUT -p ipv6-icmp -j ACCEPT

        # Drop packets to unspecified DNS
        ip netns exec wg iptables -N dns-fw
        ip netns exec wg ip6tables -N dns-fw

        ip netns exec wg iptables -A dns-fw -j DROP
        ip netns exec wg ip6tables -A dns-fw -j DROP

        ip netns exec wg iptables -I OUTPUT -p udp -m udp --dport 53 -j dns-fw
        ip netns exec wg ip6tables -I OUTPUT -p udp -m udp --dport 53 -j dns-fw

        # Set up the wireguard interface
        ip link add wg0 type wireguard
        ip link set wg0 netns wg

        # Parse wireguard INI config file
        # shellcheck disable=SC1090
        source <( \
          grep -e "DNS" -e "Address" -e "Endpoint" ${config.age.secrets.airvpn-wireguard.path} \
            | tr -d ' ' \
        )

        # Throw error when DNS is unset
        : "''${DNS:?WireGuard configuration error: missing DNS field.
        Please set DNS=<vpn_provided_dns> before continuing.}"

        # Add Addresses
        IFS=","
        # shellcheck disable=SC2154
        for addr in $Address; do
          ip -n wg address add "$addr" dev wg0
        done

        # Add DNS
        rm -rf /etc/netns/wg
        mkdir -p /etc/netns/wg
        IFS=","
        # shellcheck disable=SC2154
        for ns in $DNS; do
          echo "nameserver $ns" >> /etc/netns/wg/resolv.conf
          if [[ $ns == *"."* ]]; then
            ip netns exec wg iptables \
              -I dns-fw -p udp -d "$ns" -j ACCEPT
          else
            ip netns exec wg ip6tables \
              -I dns-fw -p udp -d "$ns" -j ACCEPT
          fi
        done

        # Strips the config of wg-quick settings
        shopt -s extglob
        strip_wgquick_config() {
          CONFIG_FILE="$1"
          [[ -e $CONFIG_FILE ]] \
            || (echo "'$CONFIG_FILE' does not exist" >&2 && exit 1)
          CONFIG_FILE="$(readlink -f "$CONFIG_FILE")"
          local interface_section=0
          while read -r line || [[ -n $line ]]; do
            key=''${line//=/ }
            [[ $key == "["* ]] && interface_section=0
            [[ $key == "[Interface]" ]] && interface_section=1
            if [ $interface_section -eq 1 ] && [[ $key =~ \
              Address|MTU|DNS|Table|PreUp|PreDown|PostUp|PostDown|SaveConfig \
            ]]
            then
              continue
            fi
            WG_CONFIG+="$line"$'\n'
          done < "$CONFIG_FILE"
          echo "$WG_CONFIG"
        }

        # Skipped ping check to support endpoints that block ICMP

        # Set wireguard config
        ip netns exec wg \
          wg setconf wg0 \
            <(strip_wgquick_config ${config.age.secrets.airvpn-wireguard.path})

        ip -n wg link set wg0 up

        # Start the loopback interface
        ip -n wg link set dev lo up

        # Create a bridge
        ip link add wg-br type bridge
        ip addr add 192.168.15.5/24 dev wg-br
        ip addr add fd93:9701:1d00::1/64 dev wg-br

        ip link set dev wg-br up

        # Set up veth pair to link namespace with host network
        ip link add veth-wg-br type veth peer \
          name veth-wg netns wg
        ip link set veth-wg-br master wg-br
        ip link set dev veth-wg-br up

        ip -n wg addr add 192.168.15.1/24 \
          dev veth-wg
        ip -n wg addr add fd93:9701:1d00::2/64 \
          dev veth-wg

        ip -n wg link set dev veth-wg up

        # Add routes
        ip -n wg route add default dev wg0
        ip -6 -n wg route add default dev wg0

        ip -n wg route add 100.64.0.0/10 via 192.168.15.5
        ip -n wg route add 10.0.0.0/8 via 192.168.15.5
        ip -n wg route add 192.168.0.0/16 via 192.168.15.5

        # Add prerouting rules
        iptables -t nat -N wg-prerouting
        iptables -t nat -A PREROUTING -j wg-prerouting
        ip6tables -t nat -N wg-prerouting
        ip6tables -t nat -A PREROUTING -j wg-prerouting

        iptables -t nat -A wg-prerouting -p tcp \
          --dport 8080 \
          -j DNAT --to-destination \
          192.168.15.1:8080
        ip6tables -t nat -A wg-prerouting -p tcp \
          --dport 8080 \
          -j DNAT --to-destination \
          \[fd93:9701:1d00::2\]:8080

        iptables -t nat -A wg-prerouting -p tcp \
          --dport 9091 \
          -j DNAT --to-destination \
          192.168.15.1:9091
        ip6tables -t nat -A wg-prerouting -p tcp \
          --dport 9091 \
          -j DNAT --to-destination \
          \[fd93:9701:1d00::2\]:9091

        # Add veth INPUT rules
        ip netns exec wg iptables -A INPUT -p tcp \
          --dport 8080 \
          -j ACCEPT -i veth-wg

        ip netns exec wg ip6tables -A INPUT -p tcp \
          --dport 8080 \
          -j ACCEPT -i veth-wg

        ip netns exec wg iptables -A INPUT -p tcp \
          --dport 9091 \
          -j ACCEPT -i veth-wg

        ip netns exec wg ip6tables -A INPUT -p tcp \
          --dport 9091 \
          -j ACCEPT -i veth-wg
      '';
    in
      lib.mkForce "${script}";
  };
}
