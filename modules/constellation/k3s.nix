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

    ingressAddress = mkOption {
      type = types.str;
      default = "10.43.0.80";
      description = ''
        Address Caddy proxies wildcard traffic to — traefik's pinned ClusterIP.

        A ClusterIP, not a NodePort or hostPort, and deliberately so. It is not an
        address on any interface: it exists only as a kube-proxy nftables rule inside
        this node's network namespace, so nothing off-box has a route to it. A NodePort
        or hostPort would bind on every local address including the Tailscale one, and
        `tailscale0` is a trusted interface — so either would silently expose the
        ingress to the whole tailnet, bypassing Caddy.

        Must be inside the k3s service CIDR (10.43.0.0/16) and unallocated.

        Changing this value after the fact causes a brief ingress outage, because
        a Service's `spec.clusterIP` is immutable: the helm upgrade applies the
        Deployment, then fails on the Service with `spec.clusterIPs[0]: Invalid
        value: may not change once set`, leaving Caddy pointed at an address no
        Service holds. helm-controller then deadlocks on its own
        `EXPECTED_RELEASE_REVISION` guard and its retry job exits doing nothing.
        Recover with `kubectl -n kube-system delete svc traefik` (helm owns it and
        recreates it at the new address) followed by `kubectl -n kube-system delete
        job helm-install-traefik`, which makes helm-controller issue a fresh job
        with a correct expected revision.
      '';
    };

    domains = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["arsfeld.dev"];
      description = ''
        Domains whose wildcard is routed into the cluster. Each entry gets a
        DNS-01 wildcard ACME certificate and a Caddy vhost for `*.<domain>`
        proxying to `ingressAddress`. The cost is one entry per domain, not per
        app: once a domain is listed, every subdomain under it is an Ingress
        with no further nix change.
      '';
    };
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
      # controller, reached through its pinned ClusterIP (ingressAddress).
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

      # Caddy reaches traefik at a pinned ClusterIP. Neither of the two
      # obvious alternatives can work here, and both were tried on this host:
      #
      #   * A NodePort at 127.0.0.1 is impossible. Task 1 puts kube-proxy in
      #     nftables mode, and that proxier deliberately excludes loopback
      #     from NodePort matching (`fib daddr type local ip daddr !=
      #     127.0.0.0/8 ... vmap @service-nodeports`) — an intentional break
      #     from the iptables proxier, not a bug, and not something
      #     nodePortAddresses can override.
      #
      #   * A hostPort with hostIP: 127.0.0.1 is impossible in this chart.
      #     templates/_podtemplate.tpl feeds ports.<name>.hostIP into *both*
      #     the pod spec's hostIP field and traefik's own
      #     --entryPoints.web.address, so traefik binds 127.0.0.1:8000 inside
      #     its own netns, where the CNI portmap DNAT — aimed at the pod's
      #     real interface IP — cannot reach it.
      #
      # A hostPort without hostIP does work, but Kubernetes then defaults the
      # binding to 0.0.0.0, and constellation.common trusts tailscale0
      # fleet-wide. A trusted interface bypasses allowedTCPPorts entirely, so
      # that would leave traefik reachable unauthenticated from every tailnet
      # peer, bypassing Caddy.
      #
      # The ClusterIP is the only candidate that is not an address on any
      # interface: it exists solely as a kube-proxy nftables rule in this
      # node's own network namespace, so no remote host has a route to it and
      # no host port is bound anywhere. The isolation is a property of the
      # address, not of a firewall rule.
      #
      # Pinned because Caddy's config is generated at nix eval time, long
      # before the cluster could allocate one.
      #
      # Note service.spec.clusterIP, not service.clusterIP: this chart
      # renders the Service spec by passing .Values.service.spec through
      # verbatim (templates/_service.tpl), which is also why an earlier
      # service.type attempt was a silently dead key.
      #
      # ports.web must not carry a redirectTo: websecure — Caddy has already
      # terminated TLS, so that redirect would be an infinite loop.
      manifests.traefik-clusterip.content = {
        apiVersion = "helm.cattle.io/v1";
        kind = "HelmChartConfig";
        metadata = {
          name = "traefik";
          namespace = "kube-system";
        };
        spec.valuesContent = ''
          service:
            spec:
              clusterIP: ${cfg.ingressAddress}
        '';
      };
    };

    # RULE: every rename of a services.k3s.manifests attribute needs its own
    # "r" entry here, forever — not just the two below.
    #
    # services.k3s.manifests is realized as one systemd-tmpfiles "L+" rule per
    # attribute name, and "L+" only creates or updates the symlink for a rule
    # that still exists — it never removes an entry whose rule disappeared.
    # Rename an attribute and the old symlink stays on disk, still declaring
    # the old content for the same Kubernetes object. If the stale name sorts
    # after the new one, k3s's manifest controller applies it last and silently
    # reverts the config on every deploy, with no error anywhere. That is a
    # real bug, found the hard way across two successive renames
    # (traefik-nodeport → traefik-hostport → traefik-clusterip, 2026-09-07),
    # and both stale names sorted after the live one.
    #
    # Harmless to leave in place once the files are gone; kept so a rollback to
    # a generation older than the rename cannot resurrect them.
    systemd.tmpfiles.rules = [
      "r /var/lib/rancher/k3s/server/manifests/traefik-nodeport.yaml"
      "r /var/lib/rancher/k3s/server/manifests/traefik-hostport.yaml"
    ];

    # Host-level trust for the pod network, the same pattern already used for
    # podman0. Nothing is added to allowedTCPPorts and no per-service rule is
    # written. The API server needs no rule at all: constellation.common
    # already trusts tailscale0 fleet-wide, so :6443 is reachable from the
    # tailnet and from nowhere else.
    networking.firewall.trustedInterfaces = ["cni0" "flannel.1"];

    # One ACME cert and one Caddy wildcard vhost per domain. ACME here is
    # DNS-01 through Cloudflare (modules/media/config.nix sets the defaults),
    # so no inbound challenge is needed and apex names, wildcards and
    # orange-clouded records all work.
    #
    # arsfeld.dev's cert is also declared in exactly one other place,
    # modules/constellation/sites/arsfeld-dev.nix, with the same
    # extraDomainNames. security.acme.certs.<d>.extraDomainNames concatenates
    # rather than dedupes, so the list evaluates to two identical entries —
    # which ACME tolerates. A redundant third declaration in
    # hosts/basestar/configuration.nix was deleted alongside this one; keep the
    # count at two, and check it with:
    #   nix eval --json .#nixosConfigurations.basestar.config \
    #     .security.acme.certs.\"arsfeld.dev\".extraDomainNames
    security.acme.certs =
      listToAttrs (map (d: nameValuePair d {extraDomainNames = ["*.${d}"];}) cfg.domains);

    services.caddy.virtualHosts = listToAttrs (map (d:
      nameValuePair "*.${d}" {
        useACMEHost = d;
        extraConfig = ''
          encode zstd gzip

          reverse_proxy ${cfg.ingressAddress}:80 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
          }
        '';
      })
    cfg.domains);

    environment.systemPackages = [pkgs.kubectl];
  };
}
