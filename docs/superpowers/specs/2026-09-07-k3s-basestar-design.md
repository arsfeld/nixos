# k3s on basestar (design)

**Date:** 2026-09-07
**Scope:** `modules/constellation/k3s.nix` (new), `hosts/basestar/configuration.nix`,
`hosts/basestar/k8s/` (new), `just/k8s.just` (new), `justfile`, `CLAUDE.md`
**Status:** Design approved, not implemented.

## Problem

Every service on basestar today is a `.nix` file. Adding one costs a commit, a CI build of
nine hosts, and a `just deploy` — minutes to an hour before a container that already exists
upstream is running. That is the right price for `media.services`, which buys standardized
PUID/PGID, gateway registration, and image watching. It is the wrong price for "run this
image at this hostname."

The want is a second, cheaper way onto basestar: declarative namespaces and volumes, images
that did not come from this flake, and a deploy that takes seconds. Kubernetes is the
obvious shape for that, and there is precedent — can-1 has run k3s + ArgoCD for 280 days.

But can-1 is also the argument for restraint. Measured 2026-09-07: **33 pods, 57% of node
memory**, of which only six are workloads (`iroh-relay`, `metadata-relay` + redis,
`plausible` + two DBs). The rest is platform — ArgoCD's seven pods, cert-manager's three,
external-dns, traefik, oauth2-proxy, and a full Prometheus + VictoriaMetrics + Grafana +
vmagent stack. That ratio is the thing to avoid repeating.

This repo has also been here before: `b540e25` added `modules/constellation/k3s.nix` and a
375-line `modules/media/kubernetes.nix` k8s backend for `media.containers` in February;
`0f23f9d` deleted both in April. The mistake that time was coupling the cluster to the
media stack. This design does not touch `media.services` at all.

## Scope

basestar only. galactica's 37 `media.services` declarations stay exactly where they are.
This spec succeeds when one non-nix app is reachable on the internet at a hostname, and
fails if it grows a second subsystem.

Explicitly **not** in this spec: galactica; retiring can-1 or moving its workloads;
migrating basestar's existing services into the cluster; cert-manager, external-dns,
ArgoCD, or in-cluster monitoring. Each is its own spec, and each is cheaper once this one
exists.

## Architecture

Four decisions, each of which removes something can-1 needs:

| Concern | can-1 | basestar | What it saves |
|---|---|---|---|
| TLS | cert-manager (3 pods) | existing `security.acme` wildcard cert | 3 pods, a cert lifecycle |
| DNS | external-dns (1 pod) | existing `*.arsfeld.dev` CNAME | 1 pod, Cloudflare API writes |
| Delivery | ArgoCD (7 pods) | nix at activation + `kubectl` | 7 pods, a CRD surface |
| Edge | traefik owns `:80`/`:443` | Caddy keeps them, traefik on a NodePort | fail2ban and the existing vhosts stay untouched |

Platform cost lands at roughly **1.2 GiB** — k3s server, traefik, coredns, metrics-server,
local-path — against 18 GiB available on a box sitting at load 0.2.

### The cluster

A new `constellation.k3s` module, enabled on basestar only. Single-node server, sqlite
backed; no etcd, no `clusterInit`.

```nix
services.k3s = {
  enable = true;
  role = "server";
  package = pkgs.k3s_1_35;
  disable = [ "servicelb" ];
  extraFlags = [ "--tls-san=basestar.bat-boa.ts.net" ];
  extraKubeProxyConfig.mode = "nftables";
  gracefulNodeShutdown.enable = true;
};
```

Every line there is load-bearing:

- **`disable = ["servicelb"]`.** servicelb exists to bind `:80`/`:443` on the host, which
  is precisely what Caddy owns. Traefik itself stays — it is the in-cluster ingress
  controller, and it is the one piece of can-1's platform worth keeping, because it is
  already familiar.
- **`package = pkgs.k3s_1_35`.** nixpkgs carries `k3s_1_30` through `k3s_1_36` as separate
  attributes, and the default `k3s` attribute floats. Kubernetes does not support skipping
  minor versions on upgrade, and the `Weekly Update` job runs `nix flake update`
  unattended every Sunday. Unpinned, that job can silently move the cluster a minor version
  — or two. Pinned, a k8s upgrade is a deliberate one-line commit.
- **`extraKubeProxyConfig.mode = "nftables"`.** `constellation.common` sets
  `networking.nftables.enable = true` fleet-wide (`common.nix:224`). kube-proxy's default
  iptables mode reaches nftables through the iptables-nft shim, which upstream
  [warns can interfere with other nftables users on the host](https://kubernetes.io/blog/2025/02/28/nftables-kube-proxy/).
  On this box the other users are fail2ban and the base firewall. Native nftables mode has
  been beta since k8s 1.31; this is 1.35.
- **`--tls-san`.** Without it the API server certificate does not cover the Tailscale name
  and `kubectl` from raider fails verification against a cert that looks fine in every
  other respect.

Firewall: `trustedInterfaces += [ "cni0" "flannel.1" ]`, host-level, exactly the pattern
already used for `podman0`. Nothing is added to `allowedTCPPorts` and no per-service rule
is written, per the standing convention. **The API needs no firewall change at all** —
`tailscale0` is already trusted fleet-wide (`common.nix:241`), so `:6443` is reachable from
raider and from nowhere else.

### The edge

Caddy keeps `:80` and `:443`. Traefik's Service becomes `type: NodePort` with a pinned
`web` nodePort of 30080, set through a `HelmChartConfig` in `kube-system`. One new Caddy
vhost per domain proxies the wildcard to it:

```
*.arsfeld.dev  ->  reverse_proxy 127.0.0.1:30080   (useACMEHost = "arsfeld.dev")
```

Because the wildcard DNS CNAME already exists and the wildcard TLS cert already exists, a
new app needs **no DNS record, no certificate, no firewall rule, and no Caddy change** —
only an Ingress with `host: foo.arsfeld.dev`. Caddy matches exact hostnames before
wildcards, so every existing explicit vhost (blog, planka, siyuan, niks3, radicle, gatus,
the apex, `www`, and the attic tombstone) keeps winning, unchanged. Migrating one into the
cluster later is: delete its nix vhost, add an Ingress.

Traefik terminates nothing. Caddy holds TLS; traffic from Caddy to the NodePort is plain
HTTP on loopback. Two traefik values need setting and are easy to miss: `ports.web` must
not carry a `redirectTo: websecure` (Caddy has already terminated TLS, so the redirect is a
loop), and `forwardedHeaders.trustedIPs` must include the node so `X-Forwarded-For` from
Caddy survives into the pod.

**A property to accept deliberately:** the wildcard vhost carries no `forward_auth`.
Anything exposed through an Ingress is **public on the internet by default**. This is the
opposite of galactica's gateway, where Authelia is the default and `bypassAuth = true` is
the exception. Auth becomes each app's own problem, or a traefik middleware.

**A behaviour change worth recording in CLAUDE.md:** today an unmatched `*.arsfeld.dev`
name falls through to Caddy's default — HTTP 200 with a zero-byte body, the exact failure
mode documented at length around the attic tombstone. After this change it becomes a 502
from the wildcard vhost. That is strictly better, because a non-200 fails safe, but it is a
change, and the tombstone rationale in CLAUDE.md should say so.

### Extra domains

A second domain — `myapp.dev` — is a list entry, not a redesign:

```nix
constellation.k3s.domains = [ "arsfeld.dev" "myapp.dev" ];
```

Each entry generates the pair: `security.acme.certs."<d>".extraDomainNames = ["*.<d>"]`
and a Caddy vhost for `<d>` and `*.<d>` proxying to the NodePort. This works because ACME
here is **DNS-01 through Cloudflare** — `modules/media/config.nix:151` sets
`dnsProvider = "cloudflare"` with a shared sops token, and vhosts consume the result via
`useACMEHost`. No inbound challenge is needed, so apex names, wildcards, and
orange-clouded records all work.

The cost is **one nix change per domain, not per app**. Once `myapp.dev` is in the list,
every `anything.myapp.dev` is just an Ingress. That preserves the property the whole design
exists for.

Two constraints on this:

- It requires the domain's DNS to be in the Cloudflare account the sops token can edit. A
  domain hosted elsewhere cannot use DNS-01 and would need a separate HTTP-01 lifecycle
  running alongside lego — out of scope here, and a reason to move the zone instead.
- Per CLAUDE.md, basestar's `168.138.71.109` is an **ephemeral** Oracle IP with no
  `oci_core_public_ip` resource, and it is already the content of five A records across
  three zones. Every domain pointed here enlarges the set that must be updated by hand if
  the instance is ever terminated or its VNIC recreated. (Stop/start does not lose it.)

### Two lanes

Both lanes write to the same cluster. The cluster does not care which one a resource came
from.

**Lane A — nix, applied at activation.** `hosts/basestar/k8s/` holds plain Nix attrsets
with thin helpers (a `mkApp` producing the Deployment + Service + Ingress trio, so a
typical app is ~10 lines). These feed `services.k3s.manifests.<name>.content`, whose type
is `attrs` or `listOf attrs`; a list is rendered as a `v1/List` document. The module links
each generated file into `/var/lib/rancher/k3s/server/manifests` via systemd-tmpfiles, and
k3s's deploy controller applies it.

Lane A is for the platform layer (the traefik `HelmChartConfig`, namespaces, storage
classes) and for apps that have settled.

Note that `hosts/basestar/k8s/` sits under `hosts/`, **not** under `modules/` — `modules/`
is haumea-auto-loaded for every host in the fleet, and these manifests belong to one.

**Lane B — `just k8s`, pushed from raider.** A new `just/k8s.just`, shaped like `just tf`:

| Recipe | What it does |
|---|---|
| `just k8s <args>` | passthrough to `kubectl` against basestar over Tailscale |
| `just k8s-apply <path>` | `kubectl apply --server-side --validate=strict` |
| `just k8s-kubeconfig` | fetch `/etc/rancher/k3s/k3s.yaml` over SSH, rewrite `127.0.0.1` to `basestar.bat-boa.ts.net` |

`--validate=strict` is what makes plain attrsets safe without a typed schema layer: the API
server rejects unknown fields, so a typo'd `spec.replica` fails loudly at apply time. This
is most of what kubenix would have bought, without a flake input that
[warns of breaking changes](https://github.com/hall/kubenix).

Promote from Lane B to Lane A when an app settles. Lane B is also the escape hatch the
original request asked for: an app that never enters nix at all still runs here.

## Deletion is the sharp edge

Creating and updating through Lane A are clean. **Deleting is not, and it fails silently.**
Two independent gaps compound:

1. The NixOS module links manifests with systemd-tmpfiles `L+` rules
   (`nixos/modules/services/cluster/rancher/default.nix:841`). tmpfiles creates and
   replaces; it never removes an entry you stopped declaring. Drop a manifest from nix and
   the symlink stays on disk, eventually pointing at a garbage-collected store path.
2. Even with the file gone, [k3s does not delete the resources](https://docs.k3s.io/installation/packaged-components).
   Manifests are tracked as `AddOn` objects in `kube-system`, and removing the file leaves
   them running — a
   [long-standing, documented behaviour](https://github.com/k3s-io/k3s/issues/1971). The
   supported removal path is `--disable <name>`, which marks the AddOn for deletion;
   [PR #11977](https://github.com/k3s-io/k3s/pull/11977) made that cascade to resources
   that had already been dropped from the file.

Without handling this, "I deleted the app from nix and redeployed" leaves it running, and
nothing anywhere reports a problem.

The module therefore ships a reconcile oneshot, ordered after `k3s.service`, that walks
`/var/lib/rancher/k3s/server/manifests`, and for each file not in the declared set deletes
the corresponding `addons.k3s.cattle.io` object — letting k3s cascade the resource
deletion — and then removes the symlink.

The exact AddOn name derivation from the manifest filename must be confirmed against the
live cluster during implementation rather than assumed; if it does not hold, the fallback
is the documented `--disable` tombstone: move the name from `manifests` to `disable`, deploy
once, then remove both entries. That is the same shape as the attic tombstone this repo
already runs, and it is honest about its cost.

## Storage and backup

PVs use k3s's bundled `local-path` StorageClass, writing to
`/var/lib/rancher/k3s/storage/`. That path is already inside basestar's backrest `system`
plan (`hosts/basestar/configuration.nix:123` backs up `/var/lib`), so **PV data is backed
up with no new configuration** — a good property that falls out for free.

Two exclusions must be added beside the existing `/var/lib/containers` ones, for the same
reasons those exist:

- `/var/lib/rancher/k3s/agent/containerd` — image layers. Gigabytes, all re-pullable from a
  registry. Exactly the case that made `**/.local/share/containers` an exclusion after it
  turned out to be 1.56M files on galactica.
- `/var/lib/rancher/k3s/server/db` — the sqlite cluster store. A copy taken from a live
  sqlite is torn, and restoring one is worse than not having it.

That is a deliberate position, so state it plainly: **the cluster is disposable, its data is
not.** Lane A manifests live in this flake and Lane B manifests live in git, so a lost
cluster is rebuilt by deploying and re-applying. What cannot be rebuilt is PV contents,
which is exactly what the backup keeps.

## Secrets

sops-nix already decrypts to `/run/secrets/` on basestar.

**k8s Secrets must never go through `services.k3s.manifests`.** That content is rendered
into the nix store by `pkgs.formats.yaml.generate`, and the store is world-readable.

Lane A instead gets a `constellation.k3s.secrets.<name>` option that generates a systemd
oneshot, ordered after `k3s.service`, piping `/run/secrets/<x>` through
`kubectl create secret … --dry-run=client -o yaml | kubectl apply -f -`. Nothing sensitive
touches the store. Lane B does the equivalent with `sops -d` on raider.

## Budget and risks

RAM and CPU are not constraints: ~1.2 GiB of platform against 18 GiB available, on four
cores at load 0.2.

**Disk is the constraint.** basestar is at **63 GiB used of 97 GiB**, 35 GiB free, and k3s
adds a second image store beside podman's. The caveat that matters: kubelet's image GC
triggers at 85% of the *whole filesystem*, which here is shared with the nix store,
podman's images, ClickHouse, and backrest's cache. GC will not fire until ~82 GiB, and it
can be triggered by growth that has nothing to do with k3s. The answer is a disk alert in
the gatus checks already running, not a tuned threshold — lowering the threshold would make
unrelated growth evict images the cluster needs.

Risks, most likely first:

1. **kube-proxy against nftables.** The mitigation is `mode: nftables` above, but this is
   the most likely thing to bite, and what breaks if it does is fail2ban and the host
   firewall — not merely the cluster. The first deploy must inspect the rule sets rather
   than assume.
2. **Deletion silently not happening**, per the section above. Mitigated by the reconcile
   unit; verified explicitly below, because this failure is invisible.
3. **Disk exhaustion**, per above.
4. **CI cost.** Adding k3s to basestar's closure grows what CI builds and pushes for that
   host. It also means manifest edits in `hosts/basestar/k8s/` shift `self` and so change
   every host's toplevel path — verified: adding one unrelated tracked file moved
   basestar's derivation from `cw1wfa4h…` to `28vzr3nf…`. The rebuild is cheap, since a
   toplevel is mostly a symlink farm over paths that still substitute, but eval and push
   run for all nine hosts. This is the same cost `infra/` already carries, and it is the
   reason Lane B exists for iteration.

## Verification

Checks that can actually fail. A `dig` that answers proves nothing here — the wildcard
CNAME makes every name under `arsfeld.dev` resolve whether or not any of this works.

| # | Check | Passes when |
|---|---|---|
| 1 | `systemctl status k3s` and `k3s kubectl get nodes` | node `Ready` |
| 2 | `nft list ruleset` on basestar; `fail2ban-client status` | fail2ban's chains intact and populated alongside kube-proxy's |
| 3 | `curl -I https://<unused>.arsfeld.dev` | **502**, not 200 with an empty body — proves the wildcard vhost is live and failing safe |
| 4 | Deploy a trivial app via Lane A; `curl https://<app>.arsfeld.dev` | 200 with the app's body, valid cert, no DNS or Caddy change made |
| 5 | Remove that app from nix, deploy, then `k8s get all -n <ns>` | **empty** — this is risk 2, and the only check that catches it |
| 6 | `just k8s-apply` a second app from raider | reachable within seconds, no `nixos-rebuild` |
| 7 | `curl -I https://blog.arsfeld.dev` and the other existing vhosts | unchanged — exact hostnames still beat the wildcard |
| 8 | `df -h /` after images are pulled | headroom still above the 85% GC threshold |

Checks 3, 5, and 7 are the ones worth writing down: each catches a failure that is
otherwise invisible until it matters.
