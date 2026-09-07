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

    # Two "r" entries that predate the reconcile unit below, kept forever.
    #
    # The reconcile unit generalizes this: from now on a rename cleans itself
    # up, because the old name is in the state file. These two are not — they
    # were dropped before the state file existed, so reconcile can never see
    # them and only an explicit rule removes them. They also survive a rollback
    # to a generation older than the reconcile unit, which the state file
    # cannot.
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

    # Removing a manifest from nix does not remove it from the cluster, and
    # nothing anywhere reports that. tmpfiles L+ rules create and replace but
    # never remove, so the symlink survives; and k3s leaves an AddOn's
    # resources running when its file disappears (k3s-io/k3s#1971).
    #
    # The state file is what makes this safe. k3s writes its OWN packaged
    # manifests into this directory at startup - traefik.yaml, coredns.yaml,
    # local-storage.yaml, ccm.yaml, rolebindings.yaml, runtimes.yaml and the
    # metrics-server/ *directory*. Deleting "everything not declared in nix"
    # would delete coredns and traefik. Only names that nix declared on a
    # previous activation are ever eligible for removal, which is also why the
    # loop iterates the state file and never the directory - a directory entry
    # is never a candidate in the first place.
    systemd.services.k3s-manifest-reconcile = {
      description = "Remove k3s auto-deploy manifests no longer declared in nix";
      after = ["k3s.service"];
      requires = ["k3s.service"];
      wantedBy = ["multi-user.target"];
      path = [config.services.k3s.package];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        manifestDir = "/var/lib/rancher/k3s/server/manifests";
        stateFile = "/var/lib/rancher/k3s/nix-managed-manifests";
        # A store file, not a heredoc. Nix's '' strings strip common leading
        # indentation from literal lines but splice interpolations in
        # verbatim, so a multi-line list inside an indented heredoc produces
        # a first line at one indent and the rest at another, and the EOF
        # terminator's column depends on the rest of the script. writeText
        # sidesteps all of it.
        declared = pkgs.writeText "k3s-declared-manifests" (
          concatMapStrings (t: t + "\n")
          (mapAttrsToList (_: m: m.target)
            (filterAttrs (_: m: m.enable)
              (config.services.k3s.manifests // config.services.k3s.autoDeployCharts)))
        );
      in ''
        set -euo pipefail

        current=${declared}

        touch ${stateFile}

        # k3s.service being active does not mean the API answers yet.
        for _ in $(seq 1 60); do
          k3s kubectl get --raw /readyz >/dev/null 2>&1 && break
          sleep 2
        done

        # A failed removal must not advance the state file. The state file is
        # the only record that makes a name eligible for deletion at all, so
        # dropping a name that was not actually removed leaves the resources
        # running with nothing anywhere reporting it - the exact failure mode
        # this unit exists to close. On failure the manifest and the state
        # file are both left alone and the unit exits non-zero; the next
        # activation retries, and every step is idempotent.
        rc=0

        while read -r base; do
          [ -n "$base" ] || continue
          # Still declared? Leave it alone.
          grep -qxF "$base" "$current" && continue

          addon="''${base%.*}"
          file="${manifestDir}/$base"
          echo "reconcile: $base is no longer declared in nix; removing addon $addon"

          ok=1

          # Deleting the AddOn does NOT delete what it applied. k3s tracks an
          # AddOn's objects with objectset.rio.cattle.io/owner-* ANNOTATIONS,
          # not ownerReferences - the objects are cluster-scoped or live in
          # another namespace, which ownerReferences cannot express - and the
          # deploy controller has no OnRemove handler to act on them
          # (k3s-io/k3s#1971, still open). Measured on this host with k3s
          # 1.35: `kubectl delete addon whoami` succeeded, the AddOn was gone,
          # and the Namespace, Deployment, Service, Ingress and pod all kept
          # running and serving 200.
          #
          # So delete the objects from the manifest itself. It is on disk
          # precisely because tmpfiles never removed it - the other half of
          # the bug is what makes the fix possible - and it is the narrowest
          # delete available: it names exactly the objects nix declared under
          # this one attribute and cannot name anything else.
          #
          # </dev/null on the AddOn delete because this loop's stdin is the
          # state file; a child that read it would swallow the names still to
          # be processed.
          if [ -e "$file" ]; then
            if ! k3s kubectl delete -f "$file" --ignore-not-found --wait=false; then
              echo "reconcile: failed to delete $addon's objects from $file" >&2
              ok=0
            fi
          else
            echo "reconcile: $file is missing, so $addon's objects cannot be enumerated; they may still be running" >&2
          fi

          if ! k3s kubectl delete addon -n kube-system "$addon" \
            --ignore-not-found --wait=false </dev/null; then
            echo "reconcile: failed to delete addon $addon" >&2
            ok=0
          fi

          # Only once both succeeded. Removing the manifest early would throw
          # away the only list of objects a retry could work from.
          if [ "$ok" -eq 1 ]; then
            rm -f "$file"
          else
            echo "reconcile: keeping $base in ${stateFile} to retry on the next activation" >&2
            rc=1
          fi
        done < ${stateFile}

        [ "$rc" -eq 0 ] || exit 1

        install -m 0644 "$current" ${stateFile}
      '';
    };

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
