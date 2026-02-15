# Constellation k3s module
#
# This module provides k3s Kubernetes cluster configuration with support for
# multi-node clusters spanning different architectures (x86_64 and aarch64).
#
# Key features:
# - Server/agent role configuration
# - Secure node joining via sops-nix encrypted token
# - Tailscale-based cluster networking (WireGuard CNI backend)
# - Disabled Traefik (using existing Caddy gateway)
# - Disabled ServiceLB (using NodePort for service exposure)
# - Pure Nix manifest deployment via services.k3s.manifests
#
# Architecture:
# - storage (x86_64): k3s server - runs control plane and most workloads
# - cloud (aarch64): k3s agent - runs gateway-related workloads
#
# Usage:
#   # On storage (server):
#   constellation.k3s = {
#     enable = true;
#     role = "server";
#   };
#
#   # On cloud (agent):
#   constellation.k3s = {
#     enable = true;
#     role = "agent";
#     serverAddr = "https://storage.bat-boa.ts.net:6443";
#   };
{
  lib,
  config,
  pkgs,
  self,
  ...
}:
with lib; let
  cfg = config.constellation.k3s;
in {
  options.constellation.k3s = {
    enable = mkEnableOption "k3s Kubernetes cluster node";

    role = mkOption {
      type = types.enum ["server" "agent"];
      default = "server";
      description = ''
        The role of this node in the k3s cluster.
        - server: Runs the control plane and can schedule workloads
        - agent: Worker node that joins an existing server
      '';
    };

    serverAddr = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Address of the k3s server to join (for agents).
        Should be in the format "https://hostname:6443".
        Uses Tailscale hostname for secure inter-node communication.
      '';
      example = "https://storage.bat-boa.ts.net:6443";
    };

    clusterCIDR = mkOption {
      type = types.str;
      default = "10.42.0.0/16";
      description = "CIDR range for pod networking.";
    };

    serviceCIDR = mkOption {
      type = types.str;
      default = "10.43.0.0/16";
      description = "CIDR range for service networking.";
    };

    flannelBackend = mkOption {
      type = types.enum ["vxlan" "host-gw" "wireguard-native" "none"];
      default = "wireguard-native";
      description = ''
        Backend for Flannel CNI.
        - wireguard-native: Encrypted traffic, ideal for multi-node over Tailscale
        - vxlan: Standard overlay, unencrypted
        - host-gw: Layer 2 only, requires same subnet
        - none: Disable Flannel, use external CNI
      '';
    };

    disableTraefik = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Disable the built-in Traefik ingress controller.
        We use Caddy as the gateway instead.
      '';
    };

    disableServiceLB = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Disable the built-in ServiceLB (Klipper).
        We use NodePort for service exposure through Caddy.
      '';
    };

    disableLocalStorage = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Disable the built-in local-path storage provisioner.
        Enable this if using custom storage solutions.
      '';
    };

    extraServerFlags = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional flags to pass to k3s server.";
    };

    extraAgentFlags = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional flags to pass to k3s agent.";
    };

    manifests = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      description = ''
        Kubernetes manifests to deploy via k3s.
        These are passed directly to services.k3s.manifests.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Assertions
    assertions = [
      {
        assertion = cfg.role == "server" || cfg.serverAddr != null;
        message = "constellation.k3s: agents must specify serverAddr";
      }
    ];

    # Enable sops for k3s token management
    sops.secrets.k3s-token = mkIf config.constellation.sops.enable {
      sopsFile = config.constellation.sops.commonSopsFile;
      mode = "0400";
    };

    # k3s configuration
    services.k3s = {
      enable = true;
      inherit (cfg) role;

      # Use token file from sops-nix
      tokenFile = mkIf config.constellation.sops.enable config.sops.secrets.k3s-token.path;

      # Server address for agents
      serverAddr = mkIf (cfg.role == "agent") cfg.serverAddr;

      # Build disabled components list
      disable = let
        components =
          (optional cfg.disableTraefik "traefik")
          ++ (optional cfg.disableServiceLB "servicelb")
          ++ (optional cfg.disableLocalStorage "local-storage");
      in
        mkIf (components != []) components;

      # Extra flags based on role
      extraFlags = let
        serverFlags =
          [
            "--flannel-backend=${cfg.flannelBackend}"
            "--cluster-cidr=${cfg.clusterCIDR}"
            "--service-cidr=${cfg.serviceCIDR}"
            # Use Tailscale IP for node communication
            "--advertise-address=$(${pkgs.tailscale}/bin/tailscale ip -4)"
            "--tls-san=${config.networking.hostName}.bat-boa.ts.net"
          ]
          ++ cfg.extraServerFlags;
        agentFlags =
          [
            # Use Tailscale IP for node communication
            "--node-ip=$(${pkgs.tailscale}/bin/tailscale ip -4)"
          ]
          ++ cfg.extraAgentFlags;
      in
        if cfg.role == "server"
        then serverFlags
        else agentFlags;

      # Deploy manifests (server only)
      manifests = mkIf (cfg.role == "server") cfg.manifests;

      # Enable graceful node shutdown
      gracefulNodeShutdown = {
        enable = true;
        shutdownGracePeriod = "30s";
        shutdownGracePeriodCriticalPods = "10s";
      };
    };

    # Ensure k3s starts after Tailscale is up
    systemd.services.k3s = {
      after = ["tailscaled.service"];
      wants = ["tailscaled.service"];
      # Add a brief delay to ensure Tailscale has acquired an IP
      serviceConfig.ExecStartPre = mkIf (cfg.role == "server") [
        "${pkgs.coreutils}/bin/sleep 5"
      ];
    };

    # Open firewall ports for k3s
    networking.firewall = {
      # Allow k3s API server (server only)
      allowedTCPPorts = mkIf (cfg.role == "server") [6443];

      # Allow Flannel VXLAN and WireGuard
      allowedUDPPorts = [
        8472 # Flannel VXLAN
        51820 # WireGuard (if using wireguard-native)
      ];

      # Allow kubelet and node ports
      allowedTCPPortRanges = [
        {
          from = 10250;
          to = 10252;
        } # Kubelet
        {
          from = 30000;
          to = 32767;
        } # NodePort range
      ];
    };

    # kubectl for administration
    environment.systemPackages = with pkgs; [
      kubectl
      kubernetes-helm
    ];

    # Set KUBECONFIG for easy kubectl access
    environment.variables.KUBECONFIG = mkIf (cfg.role == "server") "/etc/rancher/k3s/k3s.yaml";

    # Ensure kubeconfig is readable by the admin user
    systemd.services.k3s-kubeconfig-permissions = mkIf (cfg.role == "server") {
      description = "Set k3s kubeconfig permissions";
      after = ["k3s.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/chmod 644 /etc/rancher/k3s/k3s.yaml";
      };
    };
  };
}
