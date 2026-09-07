# Single-node k3s co-habiting with the host's own Caddy and podman services.
#
# This module deliberately does NOT integrate with media.services. An earlier
# attempt (b540e25) added a Kubernetes backend to media.containers and was
# deleted two months later (0f23f9d); the coupling was the reason. The cluster
# is a second, independent way onto the host, not a replacement for the first.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.constellation.k3s;
  tsDomain = "bat-boa.ts.net";
in {
  options.constellation.k3s = {
    enable = mkEnableOption "single-node k3s cluster alongside the host's Caddy";
  };

  config = mkIf cfg.enable {
    services.k3s = {
      enable = true;
      role = "server";

      # Pinned, never the floating `pkgs.k3s`. Kubernetes does not support
      # skipping minor versions, and `Weekly Update` runs `nix flake update`
      # unattended every Sunday — an unpinned attribute lets that job move the
      # cluster a minor version, or two, with no review.
      package = pkgs.k3s_1_35;

      # servicelb exists to bind :80/:443 on the host, which is exactly what
      # Caddy owns. traefik itself stays: it is the in-cluster ingress
      # controller, reached through a NodePort in Task 3.
      disable = ["servicelb"];

      # Without this the API server certificate does not cover the Tailscale
      # name, and kubectl from raider fails verification against a certificate
      # that looks correct in every other respect.
      extraFlags = ["--tls-san=${config.networking.hostName}.${tsDomain}"];

      extraKubeProxyConfig = {
        # constellation.common sets networking.nftables.enable fleet-wide.
        # kube-proxy's default iptables mode reaches nftables through the
        # iptables-nft shim, which upstream warns can interfere with other
        # nftables users on the host — here, fail2ban and the base firewall.
        mode = "nftables";

        # Not optional. nixpkgs' own option documentation: "the kubeconfig
        # param will be overriden by clientConnection.kubeconfig, so you must
        # set the clientConnection.kubeconfig option if you want to use
        # extraKubeProxyConfig". Omit it and kube-proxy starts with no
        # credentials and never programs a single service rule.
        clientConnection.kubeconfig = "/var/lib/rancher/k3s/agent/kubeproxy.kubeconfig";
      };

      gracefulNodeShutdown.enable = true;
    };

    # Host-level trust for the pod network, the same pattern already used for
    # podman0. Nothing is added to allowedTCPPorts and no per-service rule is
    # written. The API server needs no rule at all: constellation.common
    # already trusts tailscale0 fleet-wide, so :6443 is reachable from the
    # tailnet and from nowhere else.
    networking.firewall.trustedInterfaces = ["cni0" "flannel.1"];

    environment.systemPackages = [pkgs.kubectl];
  };
}
