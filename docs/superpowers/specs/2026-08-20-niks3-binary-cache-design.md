# Replacing attic with niks3 (design)

**Date:** 2026-08-20
**Scope:** `flake.nix`, `hosts/basestar/services/`, `hosts/raider/configuration.nix`,
`modules/constellation/common.nix`, `installer-iso.nix`, `just/deploy.just`, `justfile`,
`flake-modules/dev.nix`, `.github/workflows/`, `secrets/sops/{basestar,raider}.yaml`, docs
**Status:** Design approved, not implemented.
**Depends on:** `2026-08-20-deploy-pipeline-design.md` lands first.

## Problem

`attic.arsfeld.dev` goes OOM, hangs on large uploads, and is unstable. It is also the
single point of failure for deploying the entire fleet: `weekly-deploy` runs
`nixos-rebuild` under `max-jobs = 0`, so a cache miss is a hard failure rather than a
local rebuild. When attic dies, three tier-1 hosts stop being deployable.

Measured, 2026-08-20:

- The `attic` pod has restarted **13 times in 128 days**; `attic-postgres` 12 times, both
  last restarting within the same window. Simultaneous restarts of unrelated pods point
  at the node, not at one process.
- can-1 is a **single k3s node with 7.9 GiB of RAM** running the control plane, argocd,
  cert-manager, Traefik, attic and Postgres.
- The attic container declares **no resource limits**, making it BestEffort QoS — the
  first thing evicted under node memory pressure.
- `attic-cache` holds **48.4 GiB across 34,825 objects**.

atticd is a full read/write proxy: it terminates uploads, runs zstd in-process, reassembles
NARs on read, and streams both directions through one replica. On a 7.9 GiB node shared
with a control plane, that is the whole story. The Traefik `readTimeout` tuning recorded in
CLAUDE.md, and the `nar-size-threshold = 0` chunking workaround in the manifest, are both
scar tissue from fighting this.

The fix is not a bigger node. It is to stop having a server in the data path.

## Architecture

niks3 is a coordinator, not a cache. Clients ask it for presigned S3 URLs, upload NARs
**directly to R2**, and the server only records references in PostgreSQL for GC. Nix reads
**directly from R2**. One endpoint becomes two, and only one of them is a server.

| | URL | What it is |
|---|---|---|
| **Read** | `https://cache.arsfeld.dev` | R2 bucket `nix-cache` + custom domain. No server. Serves `nix-cache-info`, `<hash>.narinfo`, `nar/*`, and niks3's generated landing page. |
| **Write** | `https://niks3.arsfeld.dev` | niks3 on basestar. DNS-only A record to `168.138.71.109`. Only CI and `just deploy` talk to it. |

### Data flow

**Push.** `nix-fast-build` (or `niks3 push`) sends the store-path set to the server. The
server registers a pending closure in Postgres and returns presigned R2 URLs. The client
compresses and PUTs each NAR straight to R2, using multipart above 100 MB, then commits the
closure. The server never handles NAR bytes.

**Pull.** Nix requests `<hash>.narinfo` from `cache.arsfeld.dev`, which is R2 behind
Cloudflare's edge. basestar is not involved and cannot make a pull fail.

### Why this fixes the failure mode

| Failure | attic today | niks3 |
|---|---|---|
| Cache server OOMs | reads and writes both die; `weekly-deploy` fails on three hosts under `max-jobs = 0` | writes fail → CI job red → tier-1 gate skips the commit, which is the existing intended behaviour. Reads unaffected. |
| Large NAR upload | hangs in atticd doing reassembly and zstd in one pod | client → R2 multipart; server sees only JSON |
| can-1 memory pressure | total cache outage | can-1 is no longer involved |

The reliability requirement moves from the server to the bucket. R2 is the same storage
attic already depends on, so this is strictly less infrastructure to keep alive, not more.

### Rejected alternatives

- **Tune attic on can-1** (memory limits, a bigger node). Addresses the symptom. atticd
  remains in the read path, so a cache outage still blocks fleet deploys.
- **Self-hosted MinIO or Garage for the bucket.** Reintroduces the dependency being
  removed: reads would again require a self-hosted machine to be up.
- **Keep the bucket, migrate in place.** niks3 uses the standard Nix binary-cache layout;
  `attic-cache` holds attic's chunk layout. A shared bucket makes "delete the old cache" a
  dangerous operation. A fresh bucket costs $0.78/month to run in parallel.
- **niks3 `--enable-read-proxy`.** Allows a private bucket, but puts basestar back in the
  read path, discarding the entire benefit.

## Components

### The flake input

The niks3 NixOS module is not in nixpkgs — only the package (1.6.0) is. Add:

```nix
niks3.url = "github:Mic92/niks3";
niks3.inputs.nixpkgs.follows = "nixpkgs";
```

The module defaults `serverPackage` to its own `callPackage`, so binary and module stay
version-locked. That is preferable to pairing a nixpkgs binary with an upstream module.

Both modules are imported per-host, not through haumea (which only auto-loads this repo's
own `modules/`): basestar imports `inputs.niks3.nixosModules.niks3`, raider imports
`inputs.niks3.nixosModules.niks3-auto-upload`.

### `hosts/basestar/services/niks3.nix` (new)

Follows the existing `siyuan.nix` shape — a plain `services.caddy.virtualHosts` entry with
`useACMEHost = "arsfeld.dev"` — not `media.services`, which is for the galactica gateway
and container stack.

```nix
services.niks3 = {
  enable = true;
  httpAddr = "127.0.0.1:5751";
  nginx.enable = false;              # Caddy owns 80/443 on basestar

  s3 = {
    endpoint = "67a60cd5057ea97341c77d16f7cd3100.r2.cloudflarestorage.com";
    bucket = "nix-cache";
    region = "auto";                 # required for R2
    accessKeyFile = config.sops.secrets.r2-access-key-id.path;
    secretKeyFile = config.sops.secrets.r2-secret-access-key.path;
  };

  apiTokenFile = config.sops.secrets.niks3-api-token.path;
  signKeyFiles = [ config.sops.secrets.niks3-sign-key.path ];
  cacheUrl     = "https://cache.arsfeld.dev";
  serverUrl    = "https://niks3.arsfeld.dev";

  oidc.providers.github = {
    issuer       = "https://token.actions.githubusercontent.com";
    audience     = "https://niks3.arsfeld.dev";
    boundClaims.repository_owner = [ "arsfeld" ];
    boundSubject = [ "repo:arsfeld/nixos:*" ];
  };

  gc = { enable = true; olderThan = "720h"; };    # 30 days; pins protect what matters
};
```

**Retention is 30 days, not attic's 6 months, because CI pins the tier-1 closures.**
See "Retention and pins" below — this is what makes auto-upload affordable.

Notes:

- **Postgres coexists with planka.** `database.createLocally = true` adds a
  `local all niks3 peer` line. `services.postgresql.authentication` is `types.lines` and
  planka uses `lib.mkAfter`, so the definitions concatenate rather than collide.
- **The upstream module is well-built**: socket activation (connections queue across a
  restart instead of being refused), `Type = "notify"` with a DB-gated 30s watchdog,
  `ProtectSystem = "strict"` with syscall filtering, and a GC timer holding a Postgres
  advisory lock.
- **Leave `maxNarSize` unset.** Multipart upload handles large closures; capping it would
  silently skip store paths and reintroduce cache misses under `max-jobs = 0`.
- **Never add an R2 lifecycle rule to `nix-cache`.** niks3's GC deletes objects based on its
  Postgres reference table. A lifecycle rule deleting objects behind its back produces
  narinfo entries pointing at absent NARs — a corrupted cache that fails only at deploy time.

### Retention and pins

A pin is a named reference to a closure that is exempt from age-based GC. The server's
delete query is explicit about it:

```sql
DELETE FROM closures
WHERE closures.updated_at < $1
  AND closures.key NOT IN (SELECT narinfo_key FROM pins);
```

`UpsertPin` keys on the pin *name*, so pushing again under the same name retargets the pin
to the new closure and lets the previous one age out normally. Object GC then walks
reachability from surviving closures, so pinning a toplevel keeps every object beneath it
alive.

This decouples two retention needs that a single `olderThan` cannot serve:

- **CI pushes with `--pin <host>`**, so galactica, basestar and raider always have a
  deploy-ready closure in the cache regardless of age. This directly protects the
  `max-jobs = 0` invariant — the closure `weekly-deploy` needs can never be GC'd out from
  under it.
- **Everything else expires in 30 days.** Intermediate paths shared with a pinned closure
  survive via reachability, so this only drops genuinely unused output.

Without pins, auto-upload would force a choice between a bloated bucket and a retention
window short enough to threaten deploys. With them, neither.

### Auto-upload on raider

`services.niks3-auto-upload` is a separate module from the server. It sets
`nix.settings.post-build-hook`, so every derivation raider builds is uploaded as it
finishes — not just what CI builds or what `just deploy` pushes.

```nix
services.niks3-auto-upload = {
  enable = true;
  serverUrl = "https://niks3.arsfeld.dev";
  authTokenFile = config.sops.secrets.niks3-api-token.path;
};
```

The hook itself does almost nothing: it writes the store path to a unix socket and exits.
That matters, because a post-build hook runs inside every build — a hook that uploaded
synchronously would serialise builds behind network I/O. A socket-activated daemon on the
other end batches 50 paths, uploads with 30-way concurrency, and exits after 60s idle.
Behind it is a SQLite queue in WAL mode, so paths survive a crash or reboot mid-upload
instead of being silently lost. The socket is `root:nixbld` mode `0660` so the nix
daemon's build users can write to it.

**raider only.** blackbird is a laptop on stable that is frequently tethered or offline;
pushing every local build over a metered link is the wrong default. galactica and basestar
are deploy targets that rarely build anything not already coming from CI.

Overlap with `just deploy` is harmless — `nix-fast-build --niks3-server` and the hook both
register closures against the same server, which skips objects it already has.

### Secrets

Four new sops entries on basestar, owned by the `niks3` user:

| Key | Origin |
|---|---|
| `niks3-api-token` | `openssl rand -base64 32` (module requires ≥36 chars) |
| `niks3-sign-key` | `nix key generate-secret --key-name cache.arsfeld.dev-1` |
| `r2-access-key-id` | copied from the existing `attic-secrets` k8s secret on can-1 |
| `r2-secret-access-key` | copied from the existing `attic-secrets` k8s secret on can-1 |

The R2 credential is reused rather than minted because the available Cloudflare API session
is denied `/accounts/{id}/tokens` (`9109 Unauthorized`). See Risks.

One more on raider: `niks3-api-token`, the same value, with `owner = "arosenfeld"` and mode
`0400`. Two consumers share it — the auto-upload daemon runs as root and can read it
regardless, and `nix-fast-build --niks3-server` picks it up from
`NIKS3_AUTH_TOKEN_FILE=/run/secrets/niks3-api-token` in the user environment. That avoids a
second copy of the token in `~/.config/niks3/auth-token`.

This is a full-write cache credential on a workstation, which is worth naming explicitly —
but it is not a regression. raider already holds an attic write token at
`~/.config/attic/config.toml` today. niks3 supports exactly one API token alongside OIDC,
so a separate lower-privilege token for raider is not available without mTLS.

### Cloudflare resources

- R2 bucket `nix-cache` in account `67a60cd5057ea97341c77d16f7cd3100`.
- Custom domain `cache.arsfeld.dev` attached to that bucket. Attaching the domain is what
  makes objects publicly readable; no separate toggle is required, and the managed
  `r2.dev` domain stays disabled.
- DNS `A` record `niks3.arsfeld.dev` → `168.138.71.109` (basestar), **grey-cloud**.

Grey-cloud is not optional. CLAUDE.md records GitHub-hosted runners hitting Cloudflare's
managed challenge (HTTP 403) on `ntfy.arsfeld.one`; `attic.arsfeld.dev` is already DNS-only
for the same reason, and `seed.arsfeld.dev` is an existing grey-cloud record to this exact
IP. The usual argument for proxying — Cloudflare's 100 MB request body limit — does not
apply, because NARs never traverse this hostname.

## Change surface

This assumes `2026-08-20-deploy-pipeline-design.md` has landed, so colmena is gone,
`attic watch-store system` has already been removed from every recipe, and `just deploy`
is `nix-fast-build` + `nixos-rebuild --store-path`.

| File | Change |
|---|---|
| `flake.nix` | add the `niks3` input |
| `hosts/basestar/services/niks3.nix` | **new** — module + Caddy vhost |
| `hosts/basestar/services/default.nix` | add `./niks3.nix` |
| `hosts/raider/configuration.nix` | `services.niks3-auto-upload`, sops secret, `NIKS3_AUTH_TOKEN_FILE` |
| `secrets/sops/basestar.yaml` | four new keys |
| `secrets/sops/raider.yaml` | `niks3-api-token` |
| `modules/constellation/common.nix:51-55` | substituter + trusted key |
| `installer-iso.nix:18` | substituter + trusted key |
| `just/deploy.just` | `--attic-cache system` → `--niks3-server https://niks3.arsfeld.dev` |
| `justfile:172-182` (`cache`) | `attic push system` → `niks3 push --server-url …` |
| `flake-modules/dev.nix:45` | `attic-client` → `niks3` |
| `.github/workflows/build.yml` | `extra_nix_config` ×2, `id-token: write`, push step |
| `.github/workflows/installer-iso.yml:26` | substituter |
| `.github/workflows/fix-ci.yml:99` | the `attic push` / HTTP 499 example text |
| `modules/constellation/weekly-deploy.nix:5,191` | comments naming attic |
| `README.md:57,60,134`, `docs/guides/getting-started.md:41` | prose |
| `CLAUDE.md` | rewrite the attic/Traefik `readTimeout` paragraph — that constraint ceases to exist |

### `nix-fast-build` integration

nix-fast-build speaks niks3 natively (same author). `--niks3-server URL` reads auth from
`~/.config/niks3/auth-token` or `$NIKS3_AUTH_TOKEN_FILE`, and runs a single upload worker
because niks3 batches internally. Provision `~/.config/niks3/auth-token` on raider so local
`just deploy` can push.

### CI push step

Upstream ships `Mic92/niks3-action@v1`, which auto-configures the substituter and a
post-build-hook. **It is deliberately not used.** Its uploads are asynchronous with a
post-step drain, and whether a failed upload fails the job is undocumented. CLAUDE.md
records that invariant as load-bearing:

> `attic push failed => job failed => weekly-deploy's tier-1 gate skips this commit`

The step therefore keeps its exact current shape — `nix build`, then the four-attempt retry
loop with a hard `::error::` exit — and only the command changes:

```bash
niks3 push --server-url https://niks3.arsfeld.dev \
           --auth-token-script /tmp/niks3-token.sh \
           --pin "${{ matrix.host }}" \
           "./result-${{ matrix.host }}"
```

`--pin` is what exempts the tier-1 closures from the 30-day GC window. Dropping it would
leave `weekly-deploy` able to fail on an aged-out closure under `max-jobs = 0`.

`niks3-token.sh` emits `{"token": …}` from GitHub's OIDC endpoint using
`$ACTIONS_ID_TOKEN_REQUEST_URL` and `$ACTIONS_ID_TOKEN_REQUEST_TOKEN`, with
`audience=https://niks3.arsfeld.dev`. This is the documented `--auth-token-script`
contract — a command printing a JSON object — and is what the action does internally.

`ATTIC_TOKEN` is deleted from GitHub secrets and replaced by nothing.

## Execution plan

Steps 1–3 are automated against the Cloudflare API and can-1 rather than performed by hand.

1. **Verify the R2 credential.** Copy `r2-access-key-id` / `r2-secret-access-key` out of
   the `attic-secrets` k8s secret and confirm they can write to a bucket other than
   `attic-cache`. This gates everything; see Risks.
2. **Provision Cloudflare.** Create `nix-cache`; attach `cache.arsfeld.dev`; create the
   grey-cloud `niks3.arsfeld.dev` A record.
3. **Generate and store secrets.** Signing key and API token into basestar's sops
   alongside the two R2 values.
4. **Commit locally — do not push yet.** Monday through Thursday. Never Friday or
   Saturday; see Cutover.
5. **Bootstrap basestar from the local tree**, bypassing the push path:

   ```bash
   nixos-rebuild switch --flake .#basestar --target-host root@basestar.bat-boa.ts.net
   ```

   Not `just deploy basestar`. That recipe's phase 1 now passes
   `--niks3-server https://niks3.arsfeld.dev`, which does not exist yet — the deploy would
   fail trying to push to the server it is in the middle of creating. This one command is
   the only place that ordering bites.
6. **Verify the server** — Testing steps 1–3.
7. **Push.** CI now runs against a live niks3 and populates the cache. Testing step 4.
8. **Verify substitutability** — Testing step 5, against raider especially.
9. **Bridge the remaining hosts** with one `just deploy @tier1`. This is also what
   activates auto-upload on raider.
10. **Leave attic running.** Retiring it is a separate, later change.

## Cutover

The switch is a single commit, but a naive one deadlocks and the sequence matters.

**The trap.** `weekly-deploy` substitutes using the **currently active** generation's
`/etc/nix/nix.conf`. After the commit, that file still lists attic and still trusts
`system:mUX40QMM…`. The new closure exists only in `cache.arsfeld.dev`, signed by a key the
running system does not trust. Under `max-jobs = 0` there is no fallback to building, so
all three tier-1 hosts fail together — arriving through key trust rather than a failed push.

**The resolution** is the post-nix-fast-build `just deploy`, which sidesteps the problem
by construction. Phase 1 builds every closure locally on raider and pushes it to niks3;
phase 2 activates via `nixos-rebuild --store-path --target-host --use-substitutes`. When a
target cannot substitute — exactly the untrusted-key case — `--use-substitutes` degrades to
copying the closure over SSH instead of failing. So `just deploy @tier1` both populates the
new cache and installs the nix.conf that trusts it, in one command, with no
`--option extra-trusted-public-keys` incantation on each host.

After that generation activates, every subsequent `weekly-deploy` is ordinary.

**Rollback.** Do not delete the argocd attic app or the `attic-cache` bucket in this
change. They live in a different repo and a different bucket, so they add no cruft here,
and they cost $0.78/month. While they exist, reverting one commit restores a fully
populated, working cache. Delete them after one clean weekly-deploy — along with the stale
empty `attic` and `attic-data` buckets from 2024.

## Testing

Run in order; each gates the next.

1. `systemctl status niks3 niks3.socket` on basestar — active, watchdog satisfied.
2. `curl https://cache.arsfeld.dev/nix-cache-info` — returns `StoreDir: /nix/store`.
3. `curl https://niks3.arsfeld.dev/api/cache-config` from outside Tailscale — proves the
   grey-cloud record resolves to Caddy and no managed challenge intercepts it.
4. A green `build.yml` run, with the push step exiting 0 on all three hosts.
5. **The gating check** — reproduces `weekly-deploy`'s constraint exactly, per host:

   ```bash
   nix build --max-jobs 0 \
     --option extra-substituters https://cache.arsfeld.dev \
     --option extra-trusted-public-keys 'cache.arsfeld.dev-1:…' \
     '.#nixosConfigurations.<host>.config.system.build.toplevel'
   ```

   Run this against **raider specifically**: vscode is unfree and never on
   `cache.nixos.org`, so raider's closure is the one that depends entirely on CI having
   pushed successfully.
6. `niks3 pins list` — three pins, one per tier-1 host, each pointing at the closure CI
   just pushed.
7. **Auto-upload**, on raider: `systemctl status niks3-auto-upload.socket`, then build
   something trivial and not already cached (`nix build nixpkgs#hello --rebuild`) and
   confirm the daemon activates, drains, and exits after its idle timeout. Check that the
   path is fetchable from `cache.arsfeld.dev`.
8. `systemctl start niks3-gc && journalctl -u niks3-gc` — GC completes without deleting a
   live closure. Confirm `niks3 pins list` is unchanged afterwards and object count fell
   only where expected.
9. One clean `weekly-deploy` run before retiring attic.

## Risks

- **The R2 credential may be bucket-scoped.** The available Cloudflare session is denied
  `/accounts/{id}/tokens`, so a replacement cannot be minted programmatically. If attic's
  existing key turns out to be scoped to `attic-cache` rather than account-wide R2, minting
  a new token in the dashboard is the one step that has to be handed back. Verified as
  execution step 1, before anything else is built.
- **Manual Cloudflare state.** Bucket, custom domain and R2 token live outside version
  control — unchanged from attic today, which has the same property.
- **Cold cache window.** Between the push and CI going green, `cache.arsfeld.dev` is
  nearly empty and any rebuild builds from source. Harmless except for `weekly-deploy`,
  which Testing step 5 gates. This is why the work lands early in the week.
- **basestar joins the push path.** Deploying or rebooting basestar during a CI run fails
  that push. It fails safe: job red, tier-1 gate skips the commit.
- **niks3 is younger than attic** (~262 stars), though in production at Numtide, Clan and
  TUM-DSE, and the module quality is high. The mitigation is the un-deleted attic, not
  caution in the design.
- **Shared credential between old and new cache** until attic is retired. Acceptable
  short-term; rotate to a bucket-scoped token when `attic-cache` is deleted.
- **`post-build-hook` is a global nix setting.** Nothing in this repo sets one today
  (verified), but any future module that wants one will collide with auto-upload rather
  than compose with it.
- **Bucket growth is now driven by local work, not just CI.** Every derivation raider
  builds lands in R2. The 30-day window plus pins is what bounds this; if the bucket grows
  past expectations, shorten `olderThan` rather than disabling auto-upload — pins mean a
  shorter window does not endanger deploys. Watch the R2 storage metric after the first
  month.

## Out of scope

- mTLS, multi-key rotation, and the read proxy.
- Auto-upload on blackbird, galactica or basestar. See "Auto-upload on raider".
- Retiring the argocd attic app and deleting `attic-cache` — deliberately deferred so
  rollback stays available.
