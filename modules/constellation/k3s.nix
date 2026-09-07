# Single-node k3s co-habiting with the host's own Caddy and podman services.
#
# This module deliberately does NOT integrate with media.services. An earlier
# attempt (b540e25, 2026-02-14) added a Kubernetes backend to media.containers
# and was deleted 23 days later (0f23f9d); the coupling was the reason. The cluster
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

    secrets = mkOption {
      default = {};
      description = ''
        Kubernetes Secrets built at activation from files on disk, normally
        sops-nix paths under /run/secrets.

        These deliberately do NOT go through services.k3s.manifests: that
        content is rendered into the nix store by pkgs.formats.yaml.generate,
        and the store is world-readable.

        Rotation is handled: the generated unit re-runs on every activation,
        so changing the *content* of a file on disk (a resealed sops secret,
        say) reaches the cluster on the next deploy with nothing extra for
        the caller to declare. That is why the unit is a plain oneshot and
        not RemainAfterExit — see the comment on the unit below, and do not
        add RemainAfterExit back.

        There is no reconcile path for removed entries, unlike the manifest
        reconcile unit below: deleting a `constellation.k3s.secrets.<name>`
        attribute removes the systemd unit that created it, but not the
        Secret object itself. That asymmetry is deliberate, not an oversight
        — secrets are few and long-lived, and the k8s object is harmless once
        its consumer is gone. Delete it by hand with `kubectl delete secret`
        if it matters.
      '';
      example = literalExpression ''
        {
          myapp-db.keys.password = config.sops.secrets.myapp-db-password.path;
        }
      '';
      type = types.attrsOf (types.submodule {
        options = {
          namespace = mkOption {
            type = types.str;
            default = "default";
            description = "Namespace to create the Secret in.";
          };
          keys = mkOption {
            type = types.attrsOf types.path;
            default = {};
            description = "Map of Secret key to the file on disk holding its value.";
          };
        };
      });
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
      #   * A NodePort at 127.0.0.1 is impossible. extraKubeProxyConfig above
      #     puts kube-proxy in nftables mode, and that proxier deliberately
      #     excludes loopback from NodePort matching — an intentional break
      #     from the iptables proxier, not a bug, and not something
      #     nodePortAddresses can override. Check the effect, not the rule
      #     text: in `nft list table ip kube-proxy` the nodeport-ips set holds
      #     the node's real address (10.0.0.33) and never a loopback one. The
      #     syntax varies across kube-proxy versions — it has been seen here
      #     both as a negated 127.0.0.0/8 prefix and as set membership, and it
      #     changed shape on this host within a single day — so a comment or a
      #     grep that quotes the rule verbatim rots while the behaviour holds.
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
      # no host port is bound anywhere. That isolation is a property of the
      # address rather than of a firewall rule — which is what lets it hold
      # without one.
      #
      # But only if the Service is ClusterIP as well. Pinning
      # service.spec.clusterIP does NOT stop the chart's default type
      # (LoadBalancer) from also allocating NodePorts, and it did not: this
      # Service carried 80:31575 and 443:31396 on the node address until
      # 2026-09-07. Nothing on the host gated them. kube-proxy DNATs a
      # NodePort at prerouting, so the packet is *forwarded* and never enters
      # `inet nixos-fw input`, and networking.firewall.filterForward = false
      # leaves the forward hook at policy accept with no `nixos-fw forward`
      # chain at all — allowedTCPPorts is simply not in that path. Only
      # Oracle's security list stood in front of them. The latent half is
      # worse than the live one: this Service is ipFamilyPolicy
      # PreferDualStack, basestar's public IPv6 is already in `nft list set
      # ip6 kube-proxy nodeport-ips`, and OCI's v6 ingress rule is ::/0 for
      # all protocols — so switching k3s to dual-stack would have put traefik
      # on the public internet, past Caddy and past the host firewall, with no
      # change to this file. `type: ClusterIP` allocates no node port to leak.
      #
      # The address is pinned because Caddy's config is generated at nix eval
      # time, long before the cluster could allocate one.
      #
      # Note service.spec.<key>, not service.<key>: this chart renders the
      # Service spec by passing .Values.service.spec through verbatim
      # (templates/_service.tpl), which is why an earlier top-level
      # service.type attempt was a silently dead key. Both settings below go
      # under service.spec for that reason.
      #
      # ports.web must not carry a redirectTo: websecure — Caddy has already
      # terminated TLS, so that redirect would be an infinite loop.
      #
      # DO NOT RENAME THIS ATTRIBUTE. Renaming it is materially more dangerous
      # than renaming an app manifest, and the danger is invisible from here.
      #
      # k3s-manifest-reconcile (below) removes a dropped manifest by running
      # `kubectl delete -f` over the OLD file — that is the only way to delete
      # an AddOn's objects, because deleting the AddOn itself deletes nothing
      # (k3s tracks them with objectset.rio.cattle.io/owner-* annotations, not
      # ownerReferences, so Kubernetes GC has nothing to cascade on; verified
      # on this host against the live HelmChartConfig, which carries
      # ownerReferences: None and owner-name: traefik-clusterip).
      #
      # An app manifest owns only its own objects, so deleting from the old
      # file and recreating from the new one is a no-op in the steady state.
      # This one is different: every traefik-* name past and present renders
      # the SAME object, HelmChartConfig/traefik in kube-system. A rename
      # therefore makes reconcile delete the live HelmChartConfig out from
      # under helm-controller. The outcome is not a brief flap — it is the
      # failure described at length in the ingressAddress docstring above:
      # helm-controller deadlocks on its own EXPECTED_RELEASE_REVISION guard,
      # its retry job exits doing nothing, Caddy is left proxying to an
      # address no Service holds, and recovery is by hand with
      #   kubectl -n kube-system delete svc traefik
      #   kubectl -n kube-system delete job helm-install-traefik
      #
      # To change the pinned address, change cfg.ingressAddress. The attribute
      # name is not the knob.
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
              type: ClusterIP
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

    # One oneshot per constellation.k3s.secrets entry, merged with the
    # k3s-manifest-reconcile unit below via `//` — a duplicate systemd.services
    # key in one attrset is an evaluation error, so these must share one
    # attribute rather than each assigning systemd.services.<name> directly.
    #
    # The value travels as a --from-file argument straight into `k3s kubectl
    # create secret`, piped to the API server; it is never written anywhere
    # this module controls, and never rendered into the nix store the way
    # services.k3s.manifests content is.
    #
    # NO RemainAfterExit HERE, deliberately. What this unit reads is the
    # *content* of a path on disk, and that content is invisible to nix: a
    # resealed sops secret changes /run/secrets/<x> without changing one byte
    # of this unit's store hash. switch-to-configuration restarts a unit whose
    # definition changed, so with RemainAfterExit=true an already-active
    # oneshot is simply left alone — the rotated value never reaches the
    # cluster and nothing anywhere says so. That is the same silent-failure
    # shape as the dropped-manifest bug the reconcile unit below exists to
    # close, and it deserves the same answer rather than a caller-side
    # convention (sops.secrets.<x>.restartUnits) that only works when someone
    # remembers it. Without RemainAfterExit the unit is inactive between
    # activations, so starting multi-user.target runs it again every time.
    # The script is idempotent and costs one `kubectl apply`, so re-running it
    # unconditionally is the cheap half of this trade.
    systemd.services =
      mapAttrs' (name: s:
        nameValuePair "k3s-secret-${name}" {
          description = "Create the ${name} Kubernetes secret from disk";
          after = ["k3s.service"];
          requires = ["k3s.service"];
          wantedBy = ["multi-user.target"];
          path = [config.services.k3s.package];
          serviceConfig.Type = "oneshot";
          script = ''
            set -euo pipefail

            for _ in $(seq 1 60); do
              k3s kubectl get --raw /readyz >/dev/null 2>&1 && break
              sleep 2
            done

            k3s kubectl create namespace ${escapeShellArg s.namespace} \
              --dry-run=client -o yaml | k3s kubectl apply -f -

            k3s kubectl create secret generic ${escapeShellArg name} \
              --namespace ${escapeShellArg s.namespace} \
              ${concatStringsSep " \\\n              "
              (mapAttrsToList (k: p: "--from-file=${escapeShellArg k}=${escapeShellArg p}") s.keys)} \
              --dry-run=client -o yaml | k3s kubectl apply -f -
          '';
        })
      cfg.secrets
      // {
        k3s-manifest-reconcile = {
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
              # Operand order mirrors nixpkgs' own enabledManifests
              # (services/cluster/rancher/default.nix:844), which is the source of
              # truth for the tmpfiles rules this list has to shadow exactly.
              (mapAttrsToList (_: m: m.target)
                (filterAttrs (_: m: m.enable)
                  (config.services.k3s.autoDeployCharts // config.services.k3s.manifests)))
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
              # </dev/null on both deletes because this loop's stdin is the state
              # file; a child that read it would swallow the names still to be
              # processed.
              #
              # The -L test is the structural half of the safety mechanism, and it
              # does not depend on the state file being intact. Every nix-managed
              # manifest is a SYMLINK into /nix/store, because that is what the
              # tmpfiles "L+" rule creates; every manifest k3s writes itself is a
              # regular file (and metrics-server is a directory). So a name that
              # resolves to anything other than a live symlink is never deleted
              # from, and is never rm'd. Get a k3s-owned name into the state file
              # somehow - a hand edit, a bad merge - and this refuses loudly
              # instead of deleting coredns.
              if [ -L "$file" ] && [ -e "$file" ]; then
                if ! k3s kubectl delete -f "$file" --ignore-not-found --wait=false </dev/null; then
                  echo "reconcile: failed to delete $addon's objects from $file" >&2
                  ok=0
                fi
              elif [ -e "$file" ]; then
                echo "reconcile: REFUSING to touch $file - it is not a symlink into the nix store, so k3s wrote it, not nix. A name k3s owns has got into ${stateFile}; fix that file. Nothing was deleted for $base." >&2
                rc=1
                continue
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

            # Atomically, via a temp file in the same directory plus a rename. A
            # plain `install` onto the live path truncates and rewrites in place,
            # so a crash or a full disk mid-write leaves a half-written state
            # file - and the state file is the record that decides what is
            # eligible for deletion at all.
            install -m 0644 "$current" ${stateFile}.new
            mv -f ${stateFile}.new ${stateFile}
          '';
        };
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
