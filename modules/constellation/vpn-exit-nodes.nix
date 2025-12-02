# Constellation VPN Exit Nodes module
#
# This module creates Tailscale exit nodes that route traffic through AirVPN
# WireGuard tunnels. It allows defining multiple exit nodes for different
# countries/regions, each appearing as a separate exit node in Tailscale.
#
# Architecture:
#   [Tailscale Client] → [Tailscale Container] → [Gluetun Container] → [AirVPN WireGuard] → [Internet]
#
# Each exit node consists of two containers:
# - gluetun-exit-<name>: Connects to AirVPN via WireGuard
# - tailscale-exit-<name>: Runs in gluetun's network namespace, advertises as exit node
#
# Key features:
# - Declarative configuration of multiple VPN exit nodes
# - Integration with sops-nix for secret management
# - Automatic Tailscale authentication and exit node advertisement
# - Health monitoring via gluetun's built-in endpoint
#
# Usage:
#   constellation.vpnExitNodes = {
#     enable = true;
#     tailscaleAuthKeyFile = config.sops.secrets.tailscale-exit-key.path;
#     nodes.brazil = {
#       country = "Brazil";
#       tailscaleHostname = "brazil-exit";
#       credentialsFile = config.sops.secrets."airvpn/brazil".path;
#     };
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.vpnExitNodes;

  # Type for a single exit node configuration
  exitNodeOpts = {
    name,
    config,
    ...
  }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to enable this exit node.";
      };

      # Server selection options (gluetun supports these)
      country = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Brazil";
        description = "Country to connect to (e.g., 'Brazil', 'United States').";
      };

      city = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Sao Paulo";
        description = "City to connect to (e.g., 'Sao Paulo', 'Amsterdam').";
      };

      region = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "South America";
        description = "Region to connect to (e.g., 'South America', 'Europe').";
      };

      serverHostname = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "br.vpn.airdns.org";
        description = "Specific server hostname to connect to.";
      };

      # Tailscale configuration
      tailscaleHostname = mkOption {
        type = types.str;
        default = "${name}-exit";
        example = "brazil-exit";
        description = "Hostname for this exit node in Tailscale network.";
      };

      # Secret configuration - use either credentialsFile OR wireguardConfigFile
      credentialsFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to the credentials file containing AirVPN WireGuard configuration.
          This file should contain environment variables:
            WIREGUARD_PRIVATE_KEY=<key>
            WIREGUARD_PRESHARED_KEY=<key>
            WIREGUARD_ADDRESSES=<ip/mask>

          Use this for AirVPN with server selection (country/city/region).
          Mutually exclusive with wireguardConfigFile.
        '';
        example = literalExpression "config.sops.secrets.\"airvpn-brazil-env\".path";
      };

      wireguardConfigFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a full WireGuard configuration file (.conf format).
          Use this if you have an existing wireguard config file.
          Server selection options (country/city/region) are ignored when using this.
          Mutually exclusive with credentialsFile.
        '';
        example = literalExpression "config.age.secrets.airvpn-wireguard.path";
      };

      # Advanced options
      gluetunImage = mkOption {
        type = types.str;
        default = "qmcgaw/gluetun:latest";
        description = "Docker image for the gluetun VPN container.";
      };

      tailscaleImage = mkOption {
        type = types.str;
        default = "tailscale/tailscale:latest";
        description = "Docker image for the Tailscale container.";
      };

      extraGluetunEnv = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Additional environment variables for gluetun container.";
      };

      extraTailscaleArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["--accept-routes"];
        description = "Additional arguments for Tailscale.";
      };
    };
  };

  # Helper function to create container pair for each exit node
  mkExitNodeContainers = name: nodeCfg: let
    gluetunName = "gluetun-exit-${name}";
    tailscaleName = "tailscale-exit-${name}";

    # Determine if using custom wireguard config or AirVPN credentials
    useCustomConfig = nodeCfg.wireguardConfigFile != null;

    # Build server selection environment variables (only used with credentialsFile)
    serverEnv =
      {}
      // (optionalAttrs (nodeCfg.country != null) {SERVER_COUNTRIES = nodeCfg.country;})
      // (optionalAttrs (nodeCfg.city != null) {SERVER_CITIES = nodeCfg.city;})
      // (optionalAttrs (nodeCfg.region != null) {SERVER_REGIONS = nodeCfg.region;})
      // (optionalAttrs (nodeCfg.serverHostname != null) {SERVER_HOSTNAMES = nodeCfg.serverHostname;});

    # Base environment for gluetun
    baseEnv = {
      # Firewall settings - allow local subnet access
      # NOTE: Do NOT include 100.64.0.0/10 (Tailscale) here!
      # FIREWALL_OUTBOUND_SUBNETS creates routing rules that conflict with
      # Tailscale's routing tables, breaking exit node return traffic.
      # Tailscale manages its own routes via table 52.
      FIREWALL_VPN_INPUT_PORTS = "";
      FIREWALL_OUTBOUND_SUBNETS = "10.0.0.0/8"; # Local network only
    };

    # Environment for AirVPN mode (with credentialsFile)
    airvpnEnv =
      baseEnv
      // {
        VPN_SERVICE_PROVIDER = "airvpn";
        VPN_TYPE = "wireguard";
      }
      // serverEnv;

    # Environment for custom wireguard config mode
    customEnv =
      baseEnv
      // {
        VPN_SERVICE_PROVIDER = "custom";
        VPN_TYPE = "wireguard";
      };
  in {
    # Gluetun container - connects to AirVPN
    ${gluetunName} = {
      image = nodeCfg.gluetunImage;

      environment =
        (
          if useCustomConfig
          then customEnv
          else airvpnEnv
        )
        // nodeCfg.extraGluetunEnv;

      environmentFiles = optional (nodeCfg.credentialsFile != null) nodeCfg.credentialsFile;

      volumes = optional useCustomConfig "${nodeCfg.wireguardConfigFile}:/gluetun/wireguard/wg0.conf:ro";

      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--device=/dev/net/tun:/dev/net/tun"
        # Enable IP forwarding for exit node traffic
        "--sysctl=net.ipv4.conf.all.src_valid_mark=1"
        "--sysctl=net.ipv4.ip_forward=1"
        "--sysctl=net.ipv6.conf.all.forwarding=1"
        "--sysctl=net.ipv6.conf.all.disable_ipv6=0"
        # Health check
        "--health-cmd=wget -q -O- http://127.0.0.1:8000/v1/publicip/ip || exit 1"
        "--health-interval=60s"
        "--health-timeout=10s"
        "--health-retries=3"
      ];
    };

    # Tailscale container - runs in gluetun's network namespace
    ${tailscaleName} = {
      image = nodeCfg.tailscaleImage;

      dependsOn = [gluetunName];

      environment = {
        TS_HOSTNAME = nodeCfg.tailscaleHostname;
        TS_STATE_DIR = "/var/lib/tailscale";
        TS_USERSPACE = "false";
        # Auth key from mounted file
        TS_AUTHKEY = "file:/run/secrets/ts-authkey";
        # Extra args passed via TS_EXTRA_ARGS
        # Note: --advertise-tags must match the tags in the auth key
        TS_EXTRA_ARGS = concatStringsSep " " ([
            "--advertise-exit-node"
            "--advertise-tags=tag:exit"
            "--accept-dns=false"
          ]
          ++ nodeCfg.extraTailscaleArgs);
      };

      volumes = [
        "tailscale-exit-${name}-state:/var/lib/tailscale"
        "${cfg.tailscaleAuthKeyFile}:/run/secrets/ts-authkey:ro"
      ];

      extraOptions = [
        # Use gluetun's network namespace
        "--network=container:${gluetunName}"
        # Tailscale needs NET_ADMIN and TUN device to create its own interface
        "--cap-add=NET_ADMIN"
        "--device=/dev/net/tun:/dev/net/tun"
      ];
    };
  };

  # Filter only enabled nodes, then merge all exit node containers
  enabledNodes = filterAttrs (_: nodeCfg: nodeCfg.enable) cfg.nodes;
  allContainers = foldAttrs recursiveUpdate {} (mapAttrsToList mkExitNodeContainers enabledNodes);
in {
  options.constellation.vpnExitNodes = {
    enable = mkEnableOption "Tailscale VPN exit nodes via AirVPN";

    nodes = mkOption {
      type = types.attrsOf (types.submodule exitNodeOpts);
      default = {};
      description = "VPN exit node definitions.";
      example = literalExpression ''
        {
          brazil = {
            country = "Brazil";
            tailscaleHostname = "brazil-exit";
            credentialsFile = config.sops.secrets."airvpn/brazil".path;
          };
          us = {
            country = "United States";
            city = "New York";
            tailscaleHostname = "us-exit";
            credentialsFile = config.sops.secrets."airvpn/us".path;
          };
        }
      '';
    };

    tailscaleAuthKeyFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing the Tailscale auth key.
        This key should be reusable and ideally have exit node capability pre-approved.
        Generate one at: https://login.tailscale.com/admin/settings/keys
      '';
      example = literalExpression "config.sops.secrets.tailscale-exit-key.path";
    };
  };

  config = mkIf cfg.enable {
    # Validate that each node has exactly one credential source
    assertions =
      mapAttrsToList (name: nodeCfg: {
        assertion = (nodeCfg.credentialsFile != null) != (nodeCfg.wireguardConfigFile != null);
        message = "VPN exit node '${name}' must specify exactly one of 'credentialsFile' or 'wireguardConfigFile', not both or neither.";
      })
      enabledNodes;

    # Ensure podman is enabled
    constellation.podman.enable = true;

    # Create all containers
    virtualisation.oci-containers.containers = allContainers;

    # Add systemd dependencies to ensure secrets are available
    # Only add sops-nix dependency if sops is being used on this host
    systemd.services =
      (mapAttrs'
        (name: _:
          nameValuePair "podman-gluetun-exit-${name}" {
            # Secrets should be available before containers start
            # Works with both ragenix (secrets in /run/agenix) and sops-nix
            after = ["network-online.target"];
            wants = ["network-online.target"];
          })
        enabledNodes)
      // (mapAttrs'
        (name: _:
          nameValuePair "podman-tailscale-exit-${name}" {
            # After Tailscale starts, fix the routing rules so that traffic TO
            # Tailscale IPs (100.64.0.0/10) uses Tailscale's routing table (52)
            # instead of gluetun's VPN table (51820).
            # Gluetun's rule 101 has higher priority than Tailscale's rule 5270,
            # so we add a rule at priority 100 to route Tailscale traffic correctly.
            serviceConfig.ExecStartPost = pkgs.writeShellScript "fix-tailscale-routing-${name}" ''
              # Wait for Tailscale to be ready and create its routing table
              sleep 5
              # Add rule to route Tailscale traffic via table 52 (priority 100 > gluetun's 101)
              ${pkgs.podman}/bin/podman exec gluetun-exit-${name} ip rule add to 100.64.0.0/10 lookup 52 priority 100 2>/dev/null || true
            '';
          })
        enabledNodes);
  };
}
