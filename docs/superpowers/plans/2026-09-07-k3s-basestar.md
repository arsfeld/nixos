# k3s on basestar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a single-node k3s cluster on basestar alongside the existing Caddy/podman services, so an app can be deployed to a public hostname without a `nixos-rebuild`.

**Architecture:** Caddy keeps `:80`/`:443` and reverse-proxies a `*.<domain>` wildcard vhost to traefik on a pinned NodePort. Because the wildcard DNS CNAME and the wildcard ACME cert already exist, a new app needs only an Ingress. Two delivery lanes write to the same cluster: Nix attrsets rendered into `services.k3s.manifests` at activation, and `kubectl` pushed from raider via `just k8s`.

**Tech Stack:** NixOS 26.05 + flake-parts + haumea, k3s 1.35 (`pkgs.k3s_1_35`), traefik (k3s-bundled), Caddy, `security.acme` DNS-01 via Cloudflare, sops-nix, just, backrest.

**Design doc:** `docs/superpowers/specs/2026-09-07-k3s-basestar-design.md`

## Global Constraints

- **Commit straight to master.** No feature branches, no worktrees — repo convention. Conventional commits: `<type>(<scope>): <subject>`, scope is `basestar`, `modules`, or `galactica`. Never mention Claude in a commit message or author.
- **Run `just fmt` (alejandra) before every commit** that touches a `.nix` file. `format.yml` fails CI otherwise.
- **No per-app firewall rules.** Never add `networking.firewall.interfaces.<x>.allowedTCPPorts` or per-service allow rules. Host-level `trustedInterfaces` only. Do not add anything to `allowedTCPPorts`.
- **Do not touch `media.services`, `media.containers`, or `media.gateway`.** This cluster is deliberately not wired into the media stack. That coupling is what got the previous k3s attempt (`b540e25`) deleted in `0f23f9d`.
- **k3s version is pinned to `pkgs.k3s_1_35`.** Never use the floating `pkgs.k3s`. Kubernetes does not support skipping minor versions and `Weekly Update` runs `nix flake update` unattended every Sunday.
- **NodePort is `30080`** everywhere it appears.
- **Deploy with `just deploy basestar`** — run from raider only. `NIKS3_AUTH_TOKEN_FILE` is set only on raider; from anywhere else phase 1 aborts after the full build with `auth token is required`.
- **basestar is aarch64.** Every image used must have an `arm64` manifest. Check before deploying: `docker manifest inspect <image> | grep arm64`.
- Never write k8s Secret content into `services.k3s.manifests` — it renders to the world-readable nix store.

---

## File Structure

| Path | Responsibility |
|---|---|
| `modules/constellation/k3s.nix` (new) | The whole cluster: `services.k3s`, firewall trust, `domains` → ACME cert + Caddy wildcard vhost, `secrets` option, manifest reconcile unit. Auto-loaded by haumea. |
| `hosts/basestar/k8s/default.nix` (new) | Lane A manifests for basestar: the `mkApp` helper and the app set. Under `hosts/`, **not** `modules/` — `modules/` is auto-loaded for every host in the fleet. |
| `hosts/basestar/configuration.nix` (modify) | Enable `constellation.k3s`; add backrest excludes. |
| `just/k8s.just` (new) | Lane B: `kubeconfig`, passthrough `kubectl`, `apply`. |
| `justfile` (modify) | `mod k8s 'just/k8s.just'`. |
| `modules/constellation/weekly-deploy.nix` (modify) | Disk-headroom check in the Sunday sweep. |
| `CLAUDE.md` (modify) | Document the cluster, the two lanes, and the wildcard behaviour change. |

---

## Task 1: The cluster comes up

**Files:**
- Create: `modules/constellation/k3s.nix`
- Modify: `hosts/basestar/configuration.nix`

**Interfaces:**
- Consumes: nothing.
- Produces: `constellation.k3s.enable` (bool). Later tasks add `domains`, `nodePort`, and `secrets` to the same `options.constellation.k3s` block.

- [ ] **Step 1: Write the failing check**

There is no unit-test harness for NixOS host config; the build itself is the first gate and the deployed host is the second. Record the check that must fail now and pass at the end of this task:

```bash
ssh root@basestar.bat-boa.ts.net 'k3s kubectl get nodes'
```
Expected right now: FAIL, `bash: k3s: command not found`.

- [ ] **Step 2: Run it to confirm it fails**

Run the command above. Confirm the failure before writing any code.

- [ ] **Step 3: Create the module**

Create `modules/constellation/k3s.nix`:

```nix
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
```

- [ ] **Step 4: Enable it on basestar**

In `hosts/basestar/configuration.nix`, beside the existing `constellation.podman.enable = true;`:

```nix
  constellation.k3s.enable = true;
```

- [ ] **Step 5: Build**

```bash
just fmt
nix build .#nixosConfigurations.basestar.config.system.build.toplevel
```
Expected: PASS. A failure here naming `clientConnection` or `extraKubeProxyConfig` means Step 3 was transcribed wrong.

- [ ] **Step 6: Deploy and run the check from Step 1**

```bash
just deploy basestar
ssh root@basestar.bat-boa.ts.net 'k3s kubectl get nodes'
```
Expected: one node, `STATUS Ready`. If it stays `NotReady` for more than 90s, read `journalctl -u k3s -n 100` on basestar.

- [ ] **Step 7: Verify kube-proxy actually programmed rules, and fail2ban survived**

This is the highest-risk item in the whole plan. What breaks if nftables mode misbehaves is the host firewall, not merely the cluster.

```bash
ssh root@basestar.bat-boa.ts.net 'nft list tables; echo ---; fail2ban-client status; echo ---; k3s kubectl -n kube-system get pods'
```
Expected: a `kube-proxy` table present in `nft list tables`; `fail2ban-client status` lists its jails as before; kube-system pods (coredns, local-path-provisioner, metrics-server, traefik) `Running`.

If the `kube-proxy` nft table is absent, kube-proxy is running without credentials — re-check `clientConnection.kubeconfig` in Step 3.

- [ ] **Step 8: Commit**

```bash
git add modules/constellation/k3s.nix hosts/basestar/configuration.nix
git commit -m "feat(basestar): run a single-node k3s cluster"
```

---

## Task 2: Reach the cluster from raider

**Files:**
- Create: `just/k8s.just`
- Modify: `justfile`

**Interfaces:**
- Consumes: the running cluster from Task 1; `--tls-san` already covers `basestar.bat-boa.ts.net`.
- Produces: `just k8s::kubeconfig`, `just k8s::k <args>`, `just k8s::apply <path>`. Later tasks use `just k8s::k` for verification.

- [ ] **Step 1: Write the failing check**

```bash
just k8s::k get nodes
```
Expected right now: FAIL, `just: error: Justfile does not contain recipe`.

- [ ] **Step 2: Run it to confirm it fails**

- [ ] **Step 3: Create `just/k8s.just`**

```just
# Cluster access for basestar's k3s.
#
# Shaped like `just tf`: the tool is resolved explicitly and the recipe is a
# passthrough, so anything kubectl accepts works without a recipe per verb.

KUBECONFIG_PATH := justfile_directory() / ".k8s/basestar.yaml"

# Fetch the cluster credentials from basestar and rewrite the server address.
# k3s writes 127.0.0.1 into its own kubeconfig, which is correct on the node
# and useless anywhere else.
kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p "$(dirname '{{ KUBECONFIG_PATH }}')"
    ssh root@basestar.bat-boa.ts.net cat /etc/rancher/k3s/k3s.yaml \
      | sed 's|https://127.0.0.1:6443|https://basestar.bat-boa.ts.net:6443|' \
      > '{{ KUBECONFIG_PATH }}'
    chmod 600 '{{ KUBECONFIG_PATH }}'
    echo "wrote {{ KUBECONFIG_PATH }}"

# `just k8s::k get pods -A`, `just k8s::k logs -n foo bar` - anything kubectl takes.
k *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ ! -f '{{ KUBECONFIG_PATH }}' ]; then
        echo "no kubeconfig; run: just k8s::kubeconfig" >&2
        exit 1
    fi
    kubectl=$(nix build --no-link --print-out-paths 'nixpkgs#kubectl')/bin/kubectl
    KUBECONFIG='{{ KUBECONFIG_PATH }}' "$kubectl" {{ ARGS }}

# Apply a manifest or kustomization from the workstation - the fast lane.
#
# --server-side --validate=strict is what makes plain attrsets safe without a
# typed schema layer: the API server rejects unknown fields, so a typo'd
# spec.replica fails loudly here instead of silently doing nothing.
apply PATH:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ ! -f '{{ KUBECONFIG_PATH }}' ]; then
        echo "no kubeconfig; run: just k8s::kubeconfig" >&2
        exit 1
    fi
    kubectl=$(nix build --no-link --print-out-paths 'nixpkgs#kubectl')/bin/kubectl
    KUBECONFIG='{{ KUBECONFIG_PATH }}' "$kubectl" apply \
        --server-side --validate=strict -f '{{ PATH }}'
```

- [ ] **Step 4: Register the module**

In `justfile`, beside the other `mod` lines at the top:

```just
mod k8s 'just/k8s.just'
```

- [ ] **Step 5: Keep the credential out of git**

Append to `.gitignore`:

```
.k8s/
```

- [ ] **Step 6: Run the check from Step 1**

```bash
just k8s::kubeconfig
just k8s::k get nodes
```
Expected: the same single `Ready` node Task 1 printed, now from raider.

- [ ] **Step 7: Confirm the credential is not staged**

```bash
git status --short --untracked-files=all | grep -c '\.k8s/' || echo "correctly ignored"
```
Expected: `correctly ignored`. If it prints a count, Step 5 did not take.

- [ ] **Step 8: Commit**

```bash
git add just/k8s.just justfile .gitignore
git commit -m "feat(modules): add just k8s recipes for basestar's cluster"
```

---

## Task 3: The edge — wildcard into the cluster

**Files:**
- Modify: `modules/constellation/k3s.nix`
- Modify: `hosts/basestar/configuration.nix`

**Interfaces:**
- Consumes: `constellation.k3s.enable` from Task 1.
- Produces: `constellation.k3s.nodePort` (port, default 30080) and `constellation.k3s.domains` (listOf str, default `[]`). Task 4 relies on an Ingress with `host: <name>.arsfeld.dev` being routable.

- [ ] **Step 1: Write the failing check**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://k3s-probe.arsfeld.dev
```
Expected right now: `200` — Caddy's default vhost answering with a zero-byte body. That is the failure mode CLAUDE.md documents around the attic tombstone. This task must turn it into `502`.

- [ ] **Step 2: Run it to confirm it returns 200**

- [ ] **Step 3: Add the options**

In `modules/constellation/k3s.nix`, extend `options.constellation.k3s`:

```nix
    nodePort = mkOption {
      type = types.port;
      default = 30080;
      description = ''
        NodePort that traefik's `web` entrypoint is pinned to, and that the
        host's Caddy reverse-proxies each wildcard vhost to.
      '';
    };

    domains = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["arsfeld.dev"];
      description = ''
        Domains whose wildcard is routed into the cluster. Each entry gets a
        DNS-01 wildcard ACME certificate and a Caddy vhost for `*.<domain>`
        proxying to `nodePort`. The cost is one entry per domain, not per app:
        once a domain is listed, every subdomain under it is an Ingress with
        no further nix change.
      '';
    };
```

- [ ] **Step 4: Pin traefik to the NodePort**

In the same file's `config` block, add to `services.k3s`:

```nix
      manifests.traefik-nodeport.content = {
        apiVersion = "helm.cattle.io/v1";
        kind = "HelmChartConfig";
        metadata = {
          name = "traefik";
          namespace = "kube-system";
        };
        # valuesContent is a YAML string the HelmChartConfig controller merges
        # into the bundled chart's values.
        spec.valuesContent = ''
          service:
            type: NodePort
          ports:
            web:
              nodePort: ${toString cfg.nodePort}
              forwardedHeaders:
                trustedIPs:
                  - 127.0.0.1/32
                  - 10.42.0.0/16
                  - 10.43.0.0/16
        '';
      };
```

Two notes for whoever reads this later:

- `ports.websecure` is deliberately left exposed. Disabling it needs a chart-version-specific spelling (`expose: false` vs `expose.default: false`), and the extra NodePort is unreachable anyway: the host firewall allows only 22/80/443 and NodePorts are not in that allowlist.
- `forwardedHeaders.trustedIPs` must cover the source address traefik actually sees. NodePort traffic is SNATed by kube-proxy under the default `externalTrafficPolicy: Cluster`, so the pod CIDR is the relevant range, not Caddy's address.

- [ ] **Step 5: Generate the certs and vhosts**

Also in the `config` block:

```nix
    # One ACME cert and one Caddy wildcard vhost per domain. ACME here is
    # DNS-01 through Cloudflare (modules/media/config.nix sets the defaults),
    # so no inbound challenge is needed and apex names, wildcards and
    # orange-clouded records all work.
    #
    # arsfeld.dev's cert is already declared in two other places
    # (hosts/basestar/configuration.nix and modules/constellation/sites/
    # arsfeld-dev.nix), both with the same extraDomainNames. A third
    # declaration merges the same way the existing pair already does.
    security.acme.certs =
      listToAttrs (map (d: nameValuePair d {extraDomainNames = ["*.${d}"];}) cfg.domains);

    services.caddy.virtualHosts =
      listToAttrs (map (d:
        nameValuePair "*.${d}" {
          useACMEHost = d;
          extraConfig = ''
            encode zstd gzip

            reverse_proxy 127.0.0.1:${toString cfg.nodePort} {
              header_up X-Real-IP {remote_host}
              header_up X-Forwarded-For {remote_host}
              header_up X-Forwarded-Proto {scheme}
            }
          '';
        })
      cfg.domains);
```

- [ ] **Step 6: Remove the pre-existing duplicate cert declaration**

`security.acme.certs."arsfeld.dev".extraDomainNames` currently evaluates to
`["*.arsfeld.dev","*.arsfeld.dev"]` — it is declared in both
`hosts/basestar/configuration.nix:212` and `modules/constellation/sites/arsfeld-dev.nix:13`,
and the module concatenates rather than dedupes. Certs work today, so ACME tolerates the
duplicate, but Step 5 adds a third. Delete the redundant block from
`hosts/basestar/configuration.nix` (the `sites` module already owns it):

```nix
  security.acme.certs."arsfeld.dev" = {
    extraDomainNames = ["*.arsfeld.dev"];
  };
```

Verify the count did not grow:

```bash
nix eval --json .#nixosConfigurations.basestar.config.security.acme.certs.\"arsfeld.dev\".extraDomainNames
```
Expected: exactly two entries, the same as today — one from the `sites` module, one from `constellation.k3s`.

- [ ] **Step 7: List the domain on basestar**

In `hosts/basestar/configuration.nix`, change the enable line added in Task 1 to:

```nix
  constellation.k3s = {
    enable = true;
    domains = ["arsfeld.dev"];
  };
```

- [ ] **Step 8: Build and deploy**

```bash
just fmt
nix build .#nixosConfigurations.basestar.config.system.build.toplevel
just deploy basestar
```

- [ ] **Step 9: Run the check from Step 1**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://k3s-probe.arsfeld.dev
```
Expected: `502`. Nothing serves that name inside the cluster, and a 502 proves the wildcard vhost is live and failing safe. A `200` means the vhost did not take; a certificate error means the wildcard SAN is missing.

- [ ] **Step 10: Verify traefik took the NodePort, and is not redirecting**

```bash
just k8s::k -n kube-system get svc traefik
just k8s::k -n kube-system get helmchartconfig traefik -o jsonpath='{.spec.valuesContent}'
ssh root@basestar.bat-boa.ts.net 'curl -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" -H "Host: k3s-probe.arsfeld.dev" http://127.0.0.1:30080/'
```
Expected: `TYPE NodePort` with `80:30080/TCP` in the PORT(S) column; the valuesContent echoing what Step 4 set; and the loopback curl returning `404` with an **empty** redirect_url.

A `301`/`308` to an `https://` URL means the chart carries `ports.web.redirectTo: websecure`. Caddy has already terminated TLS, so that redirect is an infinite loop — add `ports.web.redirectTo: ""` to the `valuesContent` in Step 4 and redeploy before continuing.

- [ ] **Step 11: Verify nothing that already worked broke**

```bash
for h in blog planka siyuan niks3 attic; do
  printf '%s ' "$h"
  curl -sS -o /dev/null -w '%{http_code}\n' "https://$h.arsfeld.dev"
done
```
Expected: `blog 200`, `planka 200`, `siyuan 200`, `niks3` any non-502 (it is an API, 401/404 is fine), `attic 410`. Exact hostnames must still beat the wildcard. **A 502 for any of these means the wildcard is shadowing a real vhost — stop and fix before continuing.**

- [ ] **Step 12: Commit**

```bash
git add modules/constellation/k3s.nix hosts/basestar/configuration.nix
git commit -m "feat(basestar): route the arsfeld.dev wildcard into k3s"
```

---

## Task 4: Lane A — nix-declared manifests and the first app

**Files:**
- Create: `hosts/basestar/k8s/default.nix`
- Modify: `hosts/basestar/configuration.nix`

**Interfaces:**
- Consumes: `constellation.k3s.domains` from Task 3.
- Produces: `mkApp` with signature `mkApp { name, image, port, host, namespace ? name, replicas ? 1, env ? {} } -> [ attrs ]` returning a list of Namespace, Deployment, Service and Ingress resources. Task 5 deletes the app this task creates.

- [ ] **Step 1: Write the failing check**

```bash
curl -sS https://whoami.arsfeld.dev
```
Expected right now: FAIL — 502 from the wildcard, since nothing serves that host.

- [ ] **Step 2: Run it to confirm it 502s**

- [ ] **Step 3: Confirm the image has an arm64 manifest**

basestar is aarch64. Check before writing anything:

```bash
nix run nixpkgs#skopeo -- inspect --raw docker://docker.io/traefik/whoami:latest | grep -c arm64
```
Expected: a count of 1 or more. If 0, pick a different image — the pod will otherwise sit in `ImagePullBackOff` with an `exec format error`.

- [ ] **Step 4: Create the manifest tree**

Create `hosts/basestar/k8s/default.nix`. This lives under `hosts/`, not `modules/`, because `modules/` is haumea-auto-loaded for every host in the fleet and these manifests belong to one:

```nix
# Lane A: manifests declared in nix and applied at activation.
#
# These render into services.k3s.manifests, whose content type is `attrs` or
# `listOf attrs`; a list becomes a single v1/List document. The k3s module
# links each generated file into /var/lib/rancher/k3s/server/manifests and the
# deploy controller applies it.
#
# Deleting an app from this file is NOT enough to remove it from the cluster -
# see the reconcile unit in modules/constellation/k3s.nix.
#
# Secrets never belong here: this content is rendered into the world-readable
# nix store. Use constellation.k3s.secrets instead.
{lib, ...}: let
  # A deployment, its service, its ingress and the namespace holding them.
  # Everything the common case needs and nothing it does not.
  mkApp = {
    name,
    image,
    port,
    host,
    namespace ? name,
    replicas ? 1,
    env ? {},
  }: [
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = namespace;
    }
    {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {inherit name namespace;};
      spec = {
        inherit replicas;
        selector.matchLabels.app = name;
        template = {
          metadata.labels.app = name;
          spec.containers = [
            {
              inherit name image;
              ports = [{containerPort = port;}];
              env =
                lib.mapAttrsToList
                (n: v: {
                  name = n;
                  value = toString v;
                })
                env;
            }
          ];
        };
      };
    }
    {
      apiVersion = "v1";
      kind = "Service";
      metadata = {inherit name namespace;};
      spec = {
        selector.app = name;
        ports = [
          {
            inherit port;
            targetPort = port;
          }
        ];
      };
    }
    {
      apiVersion = "networking.k8s.io/v1";
      kind = "Ingress";
      metadata = {inherit name namespace;};
      spec.rules = [
        {
          inherit host;
          http.paths = [
            {
              path = "/";
              pathType = "Prefix";
              backend.service = {
                inherit name;
                port.number = port;
              };
            }
          ];
        }
      ];
    }
  ];
in {
  services.k3s.manifests.whoami.content = mkApp {
    name = "whoami";
    image = "traefik/whoami:latest";
    port = 80;
    host = "whoami.arsfeld.dev";
  };
}
```

- [ ] **Step 5: Import it**

In `hosts/basestar/configuration.nix`, add to the `imports` list:

```nix
    ./k8s
```

- [ ] **Step 6: Build and deploy**

```bash
just fmt
nix build .#nixosConfigurations.basestar.config.system.build.toplevel
just deploy basestar
```

- [ ] **Step 7: Run the check from Step 1**

```bash
just k8s::k -n whoami get pods
curl -sS https://whoami.arsfeld.dev
```
Expected: one `Running` pod, and a whoami response body listing `Hostname`, `IP` and the `X-Forwarded-For` header. A valid certificate with no browser warning — no DNS record, no cert, and no Caddy change was made for this app.

- [ ] **Step 8: Record the AddOn name — Task 5 depends on it**

```bash
just k8s::k -n kube-system get addons
```
Expected: an entry corresponding to `whoami.yaml`. **Write down the exact name.** The design doc flags this as the one derivation that must be confirmed against a live cluster rather than assumed; Task 5's reconcile unit needs it.

- [ ] **Step 9: Commit**

```bash
git add hosts/basestar/k8s/default.nix hosts/basestar/configuration.nix
git commit -m "feat(basestar): add nix-declared k3s manifests and a whoami app"
```

---

## Task 5: Deletion actually deletes

**Files:**
- Modify: `modules/constellation/k3s.nix`
- Modify: `hosts/basestar/k8s/default.nix`

**Interfaces:**
- Consumes: the `whoami` app from Task 4 and the AddOn name recorded in its Step 8.
- Produces: `systemd.services.k3s-manifest-reconcile`, and the state file `/var/lib/rancher/k3s/nix-managed-manifests`.

**Why this task exists:** removing a manifest from nix does *not* remove it from the cluster, and nothing reports a problem. Two gaps compound. The NixOS module links manifests with systemd-tmpfiles `L+` rules (`nixos/modules/services/cluster/rancher/default.nix:841`), and tmpfiles never removes an entry you stopped declaring — so the symlink survives, eventually pointing at a garbage-collected store path. And even with the file gone, [k3s does not delete the resources](https://docs.k3s.io/installation/packaged-components); manifests are tracked as `AddOn` objects and removing the file leaves them running ([k3s#1971](https://github.com/k3s-io/k3s/issues/1971)).

**The trap in the obvious fix:** k3s writes its *own* packaged component manifests into the same directory at startup — `traefik.yaml`, `coredns.yaml`, `local-storage.yaml`, `ccm.yaml`, `rolebindings.yaml`. A reconcile that deletes "everything not declared in nix" deletes coredns and traefik. It must therefore diff against a state file of what nix declared *last time*, and only ever remove names that appear in that file.

- [ ] **Step 1: Write the failing check**

Remove the app, deploy, and confirm it is *still there* — demonstrating the bug before fixing it.

In `hosts/basestar/k8s/default.nix`, comment out the `services.k3s.manifests.whoami` block. Then:

```bash
just fmt && just deploy basestar
just k8s::k -n whoami get all
curl -sS -o /dev/null -w '%{http_code}\n' https://whoami.arsfeld.dev
```
Expected (the bug): the deployment, service and pod are all **still running**, and the curl still returns `200`.

- [ ] **Step 2: Confirm the stale symlink is also still on disk**

```bash
ssh root@basestar.bat-boa.ts.net 'ls -l /var/lib/rancher/k3s/server/manifests/'
```
Expected: `whoami.yaml` still present, pointing into `/nix/store`. Both halves of the bug are now demonstrated.

- [ ] **Step 3: Restore the app**

Un-comment the `whoami` block in `hosts/basestar/k8s/default.nix`. Leave it in place for the rest of this task; it is the fixture.

- [ ] **Step 4: Write the reconcile unit**

In `modules/constellation/k3s.nix`, add to the `config` block:

```nix
    # Removing a manifest from nix does not remove it from the cluster, and
    # nothing anywhere reports that. tmpfiles L+ rules create and replace but
    # never remove, so the symlink survives; and k3s leaves an AddOn's
    # resources running when its file disappears (k3s-io/k3s#1971).
    #
    # The state file is what makes this safe. k3s writes its OWN packaged
    # manifests into this directory at startup - traefik.yaml, coredns.yaml,
    # local-storage.yaml, ccm.yaml, rolebindings.yaml. Deleting "everything
    # not declared in nix" would delete coredns and traefik. Only names that
    # nix declared on a previous activation are ever eligible for removal.
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

        while read -r base; do
          [ -n "$base" ] || continue
          # Still declared? Leave it alone.
          grep -qxF "$base" "$current" && continue

          addon="''${base%.*}"
          echo "reconcile: $base is no longer declared in nix; removing addon $addon"
          k3s kubectl delete addon -n kube-system "$addon" --ignore-not-found --wait=false || true
          rm -f "${manifestDir}/$base"
        done < ${stateFile}

        install -m 0644 "$current" ${stateFile}
      '';
    };
```

Note `grep -qxF "$base" "$current"` reads the store file directly — `$current` is a store path, not a temp file, so there is nothing to clean up and no `trap` needed.

- [ ] **Step 5: Build and deploy to seed the state file**

```bash
just fmt
nix build .#nixosConfigurations.basestar.config.system.build.toplevel
just deploy basestar
ssh root@basestar.bat-boa.ts.net 'cat /var/lib/rancher/k3s/nix-managed-manifests'
```
Expected: two lines — `traefik-nodeport.yaml` and `whoami.yaml`. **Verify the AddOn name recorded in Task 4 Step 8 matches `whoami` (the filename minus its extension).** If it does not, adjust the `addon=` derivation in Step 4 to match what the cluster actually calls it, and re-deploy before continuing.

- [ ] **Step 6: Confirm k3s's own manifests were untouched**

```bash
ssh root@basestar.bat-boa.ts.net 'ls /var/lib/rancher/k3s/server/manifests/'
just k8s::k -n kube-system get pods
```
Expected: `coredns.yaml`, `local-storage.yaml`, `ccm.yaml`, `rolebindings.yaml` and `traefik.yaml` all still present; all kube-system pods still `Running`. **If coredns is gone, the state-file logic failed — revert immediately.**

- [ ] **Step 7: Now run the real check — delete the app**

Remove the `services.k3s.manifests.whoami` block from `hosts/basestar/k8s/default.nix` entirely (delete it; keep `mkApp`, which Task 4 defined and later apps use).

```bash
just fmt && just deploy basestar
just k8s::k -n whoami get all
curl -sS -o /dev/null -w '%{http_code}\n' https://whoami.arsfeld.dev
ssh root@basestar.bat-boa.ts.net 'ls /var/lib/rancher/k3s/server/manifests/'
```
Expected: `No resources found in whoami namespace.`, curl returns `502`, and `whoami.yaml` is gone from the manifests directory. This is the check that catches an otherwise invisible failure.

- [ ] **Step 8: Commit**

```bash
git add modules/constellation/k3s.nix hosts/basestar/k8s/default.nix
git commit -m "fix(basestar): remove k3s manifests dropped from nix"
```

---

## Task 6: Secrets without leaking them into the store

**Files:**
- Modify: `modules/constellation/k3s.nix`

**Interfaces:**
- Consumes: `constellation.k3s.enable`; sops-nix decrypting to `/run/secrets/`.
- Produces: `constellation.k3s.secrets.<name> = { namespace, keys }` where `keys` maps a k8s secret key to a path on disk.

- [ ] **Step 1: Write the failing check**

```bash
just k8s::k -n default get secret k3s-selftest
```
Expected right now: FAIL, `secrets "k3s-selftest" not found`.

- [ ] **Step 2: Run it to confirm it fails**

- [ ] **Step 3: Add the option**

In `modules/constellation/k3s.nix`, extend `options.constellation.k3s`:

```nix
    secrets = mkOption {
      default = {};
      description = ''
        Kubernetes Secrets built at activation from files on disk, normally
        sops-nix paths under /run/secrets.

        These deliberately do NOT go through services.k3s.manifests: that
        content is rendered into the nix store by pkgs.formats.yaml.generate,
        and the store is world-readable.
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
```

- [ ] **Step 4: Implement it**

In the `config` block:

```nix
    # One oneshot per secret. The value travels as a --from-file argument and
    # is piped straight into the API server; it is never written anywhere this
    # module controls, and never into the nix store.
    systemd.services =
      mapAttrs' (name: s:
        nameValuePair "k3s-secret-${name}" {
          description = "Create the ${name} Kubernetes secret from disk";
          after = ["k3s.service"];
          requires = ["k3s.service"];
          wantedBy = ["multi-user.target"];
          path = [config.services.k3s.package];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
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
      cfg.secrets;
```

Note the merge: Task 5 already defines `systemd.services.k3s-manifest-reconcile` in this same `config` block. Combine both into one `systemd.services` attribute — either with `mkMerge`, or by adding `k3s-manifest-reconcile` to the attrset this `mapAttrs'` produces via `//`. A duplicate `systemd.services` key in one attrset is an evaluation error.

- [ ] **Step 5: Add a temporary self-test**

In `hosts/basestar/configuration.nix`, inside the `constellation.k3s` block, add temporarily:

```nix
    secrets.k3s-selftest.keys.hostname = "/etc/hostname";
```

`/etc/hostname` is a real file with a known, non-sensitive value — it proves the mechanism without involving a real credential.

- [ ] **Step 6: Build, deploy, and run the check from Step 1**

```bash
just fmt
nix build .#nixosConfigurations.basestar.config.system.build.toplevel
just deploy basestar
just k8s::k -n default get secret k3s-selftest -o jsonpath='{.data.hostname}' | base64 -d
```
Expected: `basestar`.

- [ ] **Step 7: Prove the value is not in the nix store**

```bash
ssh root@basestar.bat-boa.ts.net \
  'grep -rl "k3s-selftest" /nix/store/*-k3s-secret-k3s-selftest.service 2>/dev/null; \
   grep -c "basestar" /nix/store/*k3s-selftest*.service 2>/dev/null || echo "value absent from store"'
```
Expected: the unit file mentions the secret *name* and the *path* `/etc/hostname`, but never the contents. This is the property the whole option exists for.

- [ ] **Step 8: Remove the self-test**

Delete the `secrets.k3s-selftest` line from `hosts/basestar/configuration.nix`, then:

```bash
just fmt && just deploy basestar
just k8s::k -n default delete secret k3s-selftest
```

The option leaves no reconcile path for removed secrets — deleting the systemd unit does not delete the Secret. That is acceptable and deliberate: secrets are few and long-lived, and the k8s object is harmless once its consumer is gone. Note it in the module comment so the asymmetry with Task 5 is not read as an oversight.

- [ ] **Step 9: Commit**

```bash
git add modules/constellation/k3s.nix hosts/basestar/configuration.nix
git commit -m "feat(basestar): build k3s secrets from disk at activation"
```

---

## Task 7: Keep k3s state out of the backups

**Files:**
- Modify: `hosts/basestar/configuration.nix:124-140` (the `constellation.backrest.plans.system.excludes` list)

**Interfaces:**
- Consumes: nothing from earlier tasks; depends only on k3s writing under `/var/lib/rancher`.
- Produces: nothing consumed later.

**Why:** basestar's backrest `system` plan backs up `/var/lib`, so PV data under `/var/lib/rancher/k3s/storage/` is captured with no new configuration — a good property worth keeping. Two siblings must be excluded for the same reasons `/var/lib/containers` already is.

- [ ] **Step 1: Write the failing check**

```bash
ssh root@basestar.bat-boa.ts.net 'du -sh /var/lib/rancher/k3s/agent/containerd /var/lib/rancher/k3s/server/db 2>/dev/null'
nix eval --json .#nixosConfigurations.basestar.config.constellation.backrest.plans.system.excludes \
  | tr ',' '\n' | grep -c rancher || echo "0 rancher excludes"
```
Expected: the `du` shows real size under `agent/containerd`, and the exclude count is `0 rancher excludes`.

- [ ] **Step 2: Run it to confirm**

- [ ] **Step 3: Add the excludes**

In `hosts/basestar/configuration.nix`, in the `excludes` list beside `"/var/lib/containers"`:

```nix
        # k3s's containerd image store. Gigabytes of layers, every one of them
        # re-pullable from a registry - the same case that made
        # **/.local/share/containers an exclusion after it turned out to be
        # 1.56M files on galactica.
        "/var/lib/rancher/k3s/agent/containerd"
        # The sqlite cluster store. A copy taken from a live sqlite is torn,
        # and restoring one is worse than not having it. The cluster is
        # disposable by design: Lane A manifests live in this flake and Lane B
        # manifests live in git, so a lost cluster is rebuilt by deploying and
        # re-applying. PV data under /var/lib/rancher/k3s/storage is what
        # cannot be rebuilt, and it stays in the backup.
        "/var/lib/rancher/k3s/server/db"
```

- [ ] **Step 4: Build and verify the excludes evaluated**

```bash
just fmt
nix eval --json .#nixosConfigurations.basestar.config.constellation.backrest.plans.system.excludes \
  | tr ',' '\n' | grep rancher
```
Expected: both paths listed.

- [ ] **Step 5: Deploy and confirm PV data is still included**

```bash
just deploy basestar
ssh root@basestar.bat-boa.ts.net 'grep -c "rancher/k3s/agent/containerd" /var/lib/backrest/config.json'
```
Expected: `1`. Confirm by reading the generated config that `/var/lib/rancher/k3s/storage` is **not** excluded — that data must keep being backed up.

- [ ] **Step 6: Commit**

```bash
git add hosts/basestar/configuration.nix
git commit -m "fix(basestar): exclude k3s image and sqlite state from backups"
```

---

## Task 8: Disk-headroom check in the weekly sweep

**Files:**
- Modify: `modules/constellation/weekly-deploy.nix` (the per-host check loop, around lines 399-460)

**Interfaces:**
- Consumes: the existing `run_on`, `CHECK_ERRS`, `HOST_BAD` and `SUMMARY` machinery in that script.
- Produces: a `disk:` field per host in the ntfy summary.

**Correction to the design doc:** the spec says the disk alert belongs "in the gatus checks already running". That is wrong — gatus does HTTP endpoint checks and has no filesystem visibility. `weekly-deploy` is the right home: it already runs per tier-1 host over Tailscale SSH, already has the three-outcome check pattern, and already posts one ntfy summary. Fix the spec line as part of Task 9.

**Why it matters:** kubelet's image GC triggers at 85% of the *whole* filesystem, shared here with the nix store, podman's images, ClickHouse and backrest's cache. basestar sits at 63 GiB of 97 GiB. GC will not fire until ~82 GiB, and unrelated growth can trigger it.

⚠️ **Per CLAUDE.md: after changing `weekly-deploy.nix`, install it once by hand with `just deploy galactica`.** A broken deployer cannot deploy its own fix, and a stale unit runs old logic against a new commit.

- [ ] **Step 1: Write the failing check**

```bash
grep -c 'DISK' modules/constellation/weekly-deploy.nix
```
Expected: `0`.

- [ ] **Step 2: Run it to confirm**

- [ ] **Step 3: Add the check**

In the per-host loop in `modules/constellation/weekly-deploy.nix`, after the `FAILED_RAW` block and before the `BACKUPS` block, add:

```bash
      # Root filesystem headroom. kubelet's image GC fires at 85% of the whole
      # filesystem, which on basestar is shared with the nix store, podman's
      # images, ClickHouse and backrest's cache - so unrelated growth can
      # trigger it, and a host can cross the line with no k3s activity at all.
      # Same three outcomes as every other check: a value, a problem, or
      # "could not run" - which is never rounded down to fine.
      if DISK_RAW=$(run_on "$h" "df --output=pcent / | tail -1" 2>>"$STATE/last-checks.log"); then
        DISK=$(printf '%s' "$DISK_RAW" | tr -dc '0-9') || {
          DISK="?"
          CHECK_ERRS="$CHECK_ERRS disk-parse"
        }
        if [ "$DISK" = "?" ] || [ -z "$DISK" ]; then
          DISK="?"
          CHECK_ERRS="$CHECK_ERRS disk-parse"
        elif [ "$DISK" -ge 85 ]; then
          HOST_BAD=1
        fi
      else
        DISK="?"
        CHECK_ERRS="$CHECK_ERRS disk"
      fi
```

- [ ] **Step 4: Put it in the summary and the state file**

At `modules/constellation/weekly-deploy.nix:481`, change:

```bash
        LINE="$LINE FAILED=[''${FAILED:-none}] STALE=[''${STALE:-none}] GEN=$GEN"
```

to:

```bash
        LINE="$LINE FAILED=[''${FAILED:-none}] STALE=[''${STALE:-none}] DISK=$DISK% GEN=$GEN"
```

Then in the `RESULTS` block immediately below (around line 488), add `--arg disk "$DISK"` to the `jq -nc` argument list beside the existing `--arg stale "$STALE"`, and add a matching `disk: $disk` field to the JSON object the filter builds. Read the filter body before editing — it must stay valid jq.

Note the `''${...}` escaping in that line: the script is a Nix string, so `${` must be written `''${` or Nix will try to interpolate it. `$DISK` needs no escaping; `''${DISK:-none}` would.

- [ ] **Step 5: Build**

```bash
just fmt
nix build .#nixosConfigurations.galactica.config.system.build.toplevel
```
Expected: PASS.

- [ ] **Step 6: Install by hand, then run it early**

```bash
just deploy galactica
ssh root@galactica.bat-boa.ts.net 'systemctl start weekly-deploy'
ssh root@galactica.bat-boa.ts.net 'journalctl -u weekly-deploy -n 60 --no-pager'
```
Expected: the run completes and the summary contains a `disk:` field for each of galactica, basestar and raider, with a plausible percentage (basestar should read ~65).

- [ ] **Step 7: Confirm the threshold logic**

```bash
ssh root@basestar.bat-boa.ts.net 'df --output=pcent / | tail -1'
```
Expected: below 85, so basestar is not flagged. If it reads ≥85, the disk problem is real and immediate — deal with it before continuing.

- [ ] **Step 8: Commit**

```bash
git add modules/constellation/weekly-deploy.nix
git commit -m "feat(galactica): check root filesystem headroom in the weekly sweep"
```

---

## Task 9: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-09-07-k3s-basestar-design.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Write the failing check**

```bash
grep -c 'k3s' CLAUDE.md
```
Expected: `0`. Note that `9e4c0c8` deliberately scrubbed k3s from the docs with the message "k3s is not implemented in this flake and never was" — that statement is now false and the docs must say so.

- [ ] **Step 2: Run it to confirm**

- [ ] **Step 3: Correct the spec's disk-alert line**

In `docs/superpowers/specs/2026-09-07-k3s-basestar-design.md`, the "Budget and risks" section says the answer is "a disk alert in the gatus checks already running". Replace that with `weekly-deploy`, per Task 8's finding: gatus does HTTP endpoint checks and has no filesystem visibility.

- [ ] **Step 4: Add a k3s section to CLAUDE.md**

After the binary-cache section, add a section covering — in the file's existing dense, why-oriented prose style, not a bullet dump:

- basestar runs a single-node k3s cluster; galactica does not. It is deliberately **not** wired into `media.services` — an earlier attempt coupled the two (`b540e25`) and was deleted (`0f23f9d`).
- Caddy keeps `:80`/`:443`; traefik sits on NodePort 30080 behind a `*.arsfeld.dev` Caddy vhost. A new app needs no DNS record, no cert, no firewall rule and no Caddy change — only an Ingress. A new *domain* costs one entry in `constellation.k3s.domains`.
- **Anything exposed through an Ingress is public.** The wildcard vhost carries no `forward_auth`, the inverse of galactica's gateway where Authelia is the default.
- **The behaviour change to record:** an unmatched `*.arsfeld.dev` name used to hit Caddy's default — HTTP 200 with a zero-byte body, the exact failure mode the attic tombstone paragraphs warn about. It is now a 502 from the wildcard vhost, which fails safe. Update the attic tombstone paragraph to say so; the tombstone is still load-bearing for `attic.arsfeld.dev` specifically, since an explicit vhost beats the wildcard and 410 is a better answer than 502.
- Two lanes: `hosts/basestar/k8s/` at activation, `just k8s::apply` from raider. Secrets go through `constellation.k3s.secrets`, never through `services.k3s.manifests` — that content lands in the world-readable nix store.
- **Deleting a manifest from nix does not delete it from the cluster** on its own; `k3s-manifest-reconcile` handles it, and it diffs against a state file because k3s writes its own packaged manifests (coredns, traefik, local-storage) into the same directory.
- k3s is pinned to `pkgs.k3s_1_35` on purpose. Kubernetes does not support skipping minor versions and `Weekly Update` bumps nixpkgs unattended.

- [ ] **Step 5: Run the check from Step 1**

```bash
grep -c 'k3s' CLAUDE.md
```
Expected: a count well above 0.

- [ ] **Step 6: Verify the whole thing still builds and the fleet is unaffected**

```bash
just fmt
nix build .#nixosConfigurations.basestar.config.system.build.toplevel
nix build .#nixosConfigurations.galactica.config.system.build.toplevel
```
Expected: both PASS.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-09-07-k3s-basestar-design.md
git commit -m "docs(modules): document the k3s cluster on basestar"
```

---

## Final verification

Run the design doc's full table end to end. These are the three that catch otherwise-invisible failures:

| # | Command | Expected |
|---|---|---|
| 3 | `curl -sS -o /dev/null -w '%{http_code}\n' https://k3s-probe.arsfeld.dev` | `502` — not `200` with an empty body |
| 5 | Deploy an app via Lane A, remove it, redeploy, `just k8s::k -n <ns> get all` | `No resources found` |
| 7 | `for h in blog planka siyuan niks3 attic; do curl -sS -o /dev/null -w "$h %{http_code}\n" https://$h.arsfeld.dev; done` | 200/200/200/non-502/410 — exact hostnames still beat the wildcard |

And the standing ones:

```bash
ssh root@basestar.bat-boa.ts.net 'nft list tables && fail2ban-client status && df -h /'
just k8s::k get nodes
just k8s::k -n kube-system get pods
```
Expected: a `kube-proxy` nft table, fail2ban jails intact, root filesystem below 85%, node `Ready`, all kube-system pods `Running`.
