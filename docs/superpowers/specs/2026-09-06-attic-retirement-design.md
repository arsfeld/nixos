# Retire attic

**Date:** 2026-09-06 (2026-09-07 UTC)
**Status:** approved, not yet implemented

## Problem

attic (`attic.arsfeld.dev`, atticd on the can-1 k3s cluster, R2 bucket
`attic-cache`) was replaced by niks3 + R2 on 2026-08-21 (`60dc149`,
`194bfe3`). CI stopped pushing to it that day. It has been retained since as a
read-only fallback on the reasoning recorded in `CLAUDE.md`: it "still serves
every path it already holds, which keeps the cold-cache window short while R2
fills."

That reasoning has expired. It is now measurably a liability rather than a
fallback.

## Evidence

All figures measured 2026-09-06/07.

**It holds nothing R2 does not.** 60 paths sampled at random from raider's live
`/run/current-system` closure (4647 paths), each queried for a narinfo at both
endpoints:

```
cache.arsfeld.dev (R2): hit=60 miss=0
attic.arsfeld.dev:      hit=2  miss=58
paths ONLY on attic:    0
```

**Its signing key is unused elsewhere.** Every R2 narinfo sampled is signed
`cache.arsfeld.dev-1:…`. Nothing in `nix-cache` was copied over from attic, so
the `system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc=` trusted key is used by
attic alone and drops cleanly with it.

**It costs latency on every path.** Nix queries every substituter for every
path. attic answers a miss in ~50 ms and misses 97% of the time — one extra
round-trip per path, on nine hosts, plus every CI job. Its `Priority: 41`
against R2's `30` orders which endpoint is *fetched* from; it does not avoid the
lookup.

**It is frozen.** `attic-cache` reads exactly 34,984 objects / 52,106,154,334
bytes at every R2 analytics datapoint across a 48-hour window — no writes, no
GC.

**Nothing else can read its storage.** None of `attic`, `attic-data`,
`attic-cache` has a custom domain, and the managed `r2.dev` domain is disabled
on all three. Only atticd's own S3 credential reaches them. (`nix-cache`, by
contrast, has `cache.arsfeld.dev` attached with SSL active.)

**Two of its three buckets are already dead.** `attic` (created 2024-05-11) and
`attic-data` (2024-05-12) — the fly.io-era storage, per
`blog/content/posts/2025/06/11/constellation-pattern.md`'s reference to
`fly-attic.fly.dev/system` — both hold **0 objects** and both carry an explicit
`delete all` lifecycle rule at `maxAge` 86400. Someone drained them and never
finished the job.

| Bucket | Objects | Size | Lifecycle |
|---|---|---|---|
| `attic` | 0 | 0 B | `delete all` @ 1 day |
| `attic-data` | 0 | 0 B | `delete all` @ 1 day |
| `attic-cache` | 34,984 | 48.5 GiB | none |
| `nix-cache` | 143,905 | 106 GiB | none (deliberate — see `CLAUDE.md`) |

48.5 GiB at R2 Standard ($0.015/GB-month) is roughly $0.78/month to store data
measured at zero unique value.

## Non-goals

- **Retiring can-1.** Still blocked on the `relay.mydia.dev` Elixir relay
  awaiting its Cloudflare Workers cutover; see
  `hosts/basestar/services/iroh-relay-README.md`. Retiring attic removes one
  more reason to keep that VPS but does not by itself free it.
- **`~/Code/attic` and `~/Code/fly-attic`.** Source repositories (an attic fork
  and the retired fly.io deployment), not running infrastructure.
- **`nix-cache` growth.** It grew 99 → 113 GB in two days on raider's
  auto-upload. niks3's 30-day GC first fires around 2026-09-20. Worth watching;
  a separate change.

## Disposition of every reference

### This repository

| Location | Action |
|---|---|
| `modules/constellation/common.nix:60` | delete the `https://attic.arsfeld.dev/system` substituter |
| `modules/constellation/common.nix:64` | delete the `system:mUX40QMM+…` trusted public key |
| `modules/constellation/common.nix:57-59` | delete the "attic is frozen … Dropped when attic is retired" comment |
| `installer-iso.nix:22` | delete substituter |
| `installer-iso.nix:26` | delete trusted key |
| `.github/workflows/build.yml:44` | drop attic from `extra-substituters`; drop `system:` from `extra-trusted-public-keys` (matrix job) |
| `.github/workflows/build.yml:117` | same (build job) |
| `.github/workflows/installer-iso.yml:26` | same |
| `infra/dns/arsfeld-dev.nix` | delete resources `a_attic_arsfeld_dev`, `txt__acme_challenge_attic_arsfeld_dev_{1,2,3}` **and their four matching `import` blocks** |
| `infra/dns/arsfeld-dev.nix:100-104` | comment says "eleven … (attic, metadata-relay, sumwhere, plane, windmill)" → **eight**, drop `attic` from the list |
| `CLAUDE.md:144-152` | rewrite the attic rollback paragraph |
| `CLAUDE.md` (infra section) | "56 resources … 50 `cloudflare_dns_record`" → **52 … 46** |

Counts verified against `just tf state list`: 50 `cloudflare_dns_record`
resources in state, matching 23 + 7 + 20 across the three zone files. Of the 11
`_acme-challenge` TXT resources, 3 are attic's; the remaining 8 are
metadata_relay (4), sumwhere (2), plane (1), windmill (1).

### Outside this repository

| Location | Action |
|---|---|
| GitHub secret `ATTIC_TOKEN` (last rotated 2026-03-22, unused since 2026-08-21) | `gh secret delete ATTIC_TOKEN` |
| `arsfeld/argocd`: `apps/attic.yaml` | delete |
| `arsfeld/argocd`: `manifests/attic/` (namespace, postgres, attic, kustomization, secret-generator) | delete |
| `arsfeld/argocd`: `scripts/attic-r2-cleanup.sh` | delete |
| `arsfeld/argocd`: `.sops.yaml` attic entry | delete |
| R2 bucket `attic-cache` | verify contents → purge → delete |
| R2 buckets `attic`, `attic-data` | delete (already empty) |
| raider `~/.config/attic/` (`config.toml` holds a live write token, `server.toml`) | delete |
| raider `~/.local/share/attic/` (`server.db`, `storage/`) | delete |

`attic-client` was already removed from the dev shell in `05ed043`; there is no
attic flake input.

## What stays, and why

Comments that name attic but explain **why the current design is what it is**
are load-bearing rationale, not stale operational claims. They stay:

- `hosts/basestar/services/niks3.nix:9-13` — "That split is the whole point of
  replacing attic … when it died, reads died with it and three tier-1 hosts
  stopped being deployable under `max-jobs = 0`." This is the argument for the
  coordinator/R2 split.
- `hosts/basestar/services/niks3.nix:55` — "30 days, not attic's 6 months,
  because CI pins the tier-1 closures."
- `modules/constellation/common.nix:52-56` — why the read path is a bucket and
  not a server.
- `justfile:72` — why niks3 upload failures fold into the exit code where the
  attic push's did not.
- `hosts/raider/configuration.nix:43-44` — why raider holding a full-write cache
  token is not a regression.

The line: **delete anything asserting attic is currently available; keep
anything explaining a decision.**

## Sequencing

Two facts discovered during design drive the order.

**The R2 credential lives in the cluster.** `scripts/attic-r2-cleanup.sh` reads
`r2-access-key-id` / `r2-secret-access-key` from the `attic-secrets` k8s secret
in namespace `attic`. It must be extracted *before* the ArgoCD app is torn down.
No new API token needs minting.

**The ArgoCD app self-heals.** `apps/attic.yaml` sets `prune: true` and
`selfHeal: true`, so a `kubectl delete` is undone on the next sync. The
Application manifest has to be removed from the repo first.

---

**Phase 1 — repository.** All config, CI and `CLAUDE.md` edits in one commit to
master. `just fmt` first. Push; CI builds all nine hosts and pushes each closure
to niks3.

*Gate: CI green.* A red build makes `weekly-deploy`'s tier-1 gate skip the
commit anyway, so nothing downstream may proceed.

**Phase 2 — deploy.** `just deploy @tier1`, from raider (the deploy driver —
`NIKS3_AUTH_TOKEN_FILE` is set only there).

*Gate: all three hosts activate, and phase-2 logs show substitution from
`cache.arsfeld.dev`.* This is the real proof: the first deploy performed with
attic absent from `substituters`.

**Phase 3 — extract the credential.** Before touching ArgoCD:

```bash
kubectl -n attic get secret attic-secrets -o jsonpath='{.data.r2-access-key-id}' | base64 -d
kubectl -n attic get secret attic-secrets -o jsonpath='{.data.r2-secret-access-key}' | base64 -d
```

Hold them in a scratch directory, never in the repository.

**Phase 4 — verify bucket contents.** Using that credential:

```bash
aws s3api list-objects-v2 \
  --endpoint-url https://67a60cd5057ea97341c77d16f7cd3100.r2.cloudflarestorage.com \
  --bucket attic-cache --max-items 20
```

*Gate: a human reads the listing and confirms it is NAR chunks and attic
metadata, nothing else.* This is a stop-and-look step, not a scripted one. It
exists because the `infra.yaml` R2 credentials are correctly scoped to `tfstate`
alone, so the bucket's contents could not be inspected during design — only its
object count, size, and the absence of any public read path.

**Phase 5 — tear down the server.** Delete `apps/attic.yaml`,
`manifests/attic/`, `scripts/attic-r2-cleanup.sh` and the `.sops.yaml` entry
from the argocd repo; commit; push. ArgoCD prunes the namespace. Then
`gh secret delete ATTIC_TOKEN`.

**Phase 6 — DNS.** Remove the four resources and their four `import` blocks from
`infra/dns/arsfeld-dev.nix`. Run `just tf plan` and **read what it names** — per
`CLAUDE.md`, a commit to `infra/` stages a real change for whoever applies next,
and a summary line is not a substitute for reading the plan. Confirm it is
exactly four destroys and nothing else, `just tf apply`, then commit. Apply
before committing so nothing is left staged for someone else.

**Phase 7 — buckets.** Purge `attic-cache`
(`aws s3 rm --recursive --endpoint-url …`), then delete all three buckets via
the Cloudflare API. `attic` and `attic-data` are already empty and need no S3
credential.

Phases 1–2 are reversible with `git revert`. Phase 5 onward is not. The ordering
places every irreversible step behind a deploy that had to succeed first.

## Verification

- Resample 60 random paths from raider's closure against `cache.arsfeld.dev`
  after Phase 2 — expect 60/60, matching the pre-change measurement.
- `nix path-info --store https://cache.arsfeld.dev` against each tier-1
  toplevel.
- After Phase 6: `dig +short attic.arsfeld.dev` returns empty.
- After Phase 7: `r2_buckets_list` returns four buckets — `mydia-flatpak`,
  `nix-cache`, `tfstate`, `whatsrev`.
- Sunday 2026-09-13 06:00 UTC: `weekly-deploy`'s ntfy summary is the real
  end-to-end confirmation, because it is the one path where a cache miss is
  fatal rather than a local rebuild (`max-jobs = 0`).

## Failure handling

Before Phase 5, recovery is `git revert` plus a redeploy.

After Phase 5 recovery is a rebuild rather than a revert, but the exposure is
bounded: a missing path becomes a local rebuild on every host and every deploy
path *except* `weekly-deploy` under `max-jobs = 0`. Work begins Monday
2026-09-07 with the next `weekly-deploy` on Sunday 2026-09-13 06:00 UTC — six
days of runway to notice and rebuild.

The pre-existing risk this removes is worth naming too: attic's disappearance
was previously an availability event, because atticd sat in the read path on a
memory-starved shared k3s node. After this change nothing we operate is in the
read path at all.
