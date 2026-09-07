# attic Retirement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove attic completely — from every NixOS host, CI, Cloudflare DNS, the can-1 k3s cluster and Cloudflare R2 — leaving niks3 + `cache.arsfeld.dev` as the only binary cache.

**Architecture:** Seven phases in strict order, each gated. Repository edits land and deploy first, proving substitution works without attic; only then does anything irreversible happen. The R2 credential needed to empty the storage bucket lives inside the cluster being torn down, so it is extracted before teardown, not after.

**Tech Stack:** NixOS + flake-parts, GitHub Actions, OpenTofu via terranix, ArgoCD on k3s (context `k3s-can1`), Cloudflare R2 + DNS, `aws` CLI, `just`.

**Spec:** `docs/superpowers/specs/2026-09-06-attic-retirement-design.md`

## Global Constraints

- **Commit style:** conventional commits, `<type>(<scope>): <subject>`. Scopes here: `modules`, `raider`, `basestar`. Never mention Claude in a commit message or as author.
- **Branching:** commit straight to `master` in the nixos repo. Do not create branches or worktrees.
- **Formatting:** run `just fmt` before committing any `.nix` change; CI's `format.yml` fails on unformatted files.
- **Deploy driver:** `just deploy` must run from **raider**. `NIKS3_AUTH_TOKEN_FILE` is set only there (`hosts/raider/configuration.nix`); phase 1 of a deploy aborts from any other host.
- **Never add an R2 lifecycle rule to `nix-cache`.** niks3's GC deletes from its own Postgres reference table; a rule deleting objects behind its back leaves narinfos pointing at absent NARs, which fails only at deploy time.
- **Deadline:** the next `weekly-deploy` is **Sunday 2026-09-13 06:00 UTC**. It runs under `max-jobs = 0`, where a cache miss is a hard failure rather than a local rebuild. All work should land well before it.
- **Cluster context:** `k3s-can1`. Verify with `kubectl config current-context` before any `kubectl` step.
- **The argocd repo has a dirty working tree** (`apps/example-app.yaml` deleted, `backlog/config.yml` modified, untracked `backlog/tasks/`, `manifests/cert-manager/cloudflare-secret.yaml.new`, untracked `scripts/attic-r2-cleanup.sh`). **Never `git add -A` or `git commit -a` there** — stage only the exact paths named in each step.

---

## File Structure

**nixos repo (`/home/arosenfeld/Code/nixos`)**

| File | Responsibility | Change |
|---|---|---|
| `modules/constellation/common.nix` | substituters + trusted keys for all 9 hosts | remove attic substituter, `system:` key, stale comment |
| `installer-iso.nix` | installer ISO's own copy of the cache config | remove attic substituter + `system:` key |
| `.github/workflows/build.yml` | per-host build + niks3 push (2 jobs) | remove attic from both `extra_nix_config` blocks |
| `.github/workflows/installer-iso.yml` | ISO build | remove attic from `extra_nix_config` |
| `infra/dns/arsfeld-dev.nix` | terranix DNS for the zone | remove 4 resources + 4 `import` blocks, fix the count comment (Task 8) |
| `CLAUDE.md` | operator documentation | Task 3 replaces the rollback paragraph (true-as-of-then); Task 8 updates the resource counts with the records it destroys; Task 10 tightens the paragraph to final |

**argocd repo (`/home/arosenfeld/Code/argocd`)**

| File | Change |
|---|---|
| `apps/attic.yaml` | delete (tracked) |
| `manifests/attic/{attic,attic-secret,kustomization,namespace,postgres,secret-generator}.yaml` | delete all 6 (tracked) |
| `.sops.yaml` | delete the `manifests/attic/.*-secret\.yaml$` creation rule |
| `scripts/attic-r2-cleanup.sh` | delete the local file (**untracked** — `rm`, not `git rm`) |

---

### Task 1: Remove attic from NixOS configuration

**Files:**
- Modify: `modules/constellation/common.nix:50-66`
- Modify: `installer-iso.nix:18-28`

**Interfaces:**
- Consumes: nothing.
- Produces: host configurations whose `nix.settings.substituters` contains exactly `https://cache.arsfeld.dev` (plus nixpkgs defaults) and whose `trusted-public-keys` no longer contains `system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc=`. Task 5 verifies this on live hosts.

- [ ] **Step 1: Record the pre-change baseline**

This is the measurement Task 5 compares against. Run from the nixos repo:

```bash
mkdir -p "$CLAUDE_JOB_DIR/tmp" && cd "$CLAUDE_JOB_DIR/tmp"
nix-store -qR /run/current-system > closure.txt
wc -l < closure.txt
shuf -n 60 closure.txt > sample.txt
hits=0
while read -r p; do
  h=$(basename "$p" | cut -d- -f1)
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://cache.arsfeld.dev/$h.narinfo")" = 200 ] && hits=$((hits+1))
done < sample.txt
echo "cache.arsfeld.dev: $hits/60"
```

Expected: `cache.arsfeld.dev: 60/60`. Keep `sample.txt` — Task 5 reuses the same 60 paths.

If this is **not** 60/60, stop and investigate before changing anything. The whole plan rests on R2 having complete coverage.

- [ ] **Step 2: Edit `modules/constellation/common.nix`**

Replace this exact block:

```nix
        substituters = lib.mkAfter [
          # The read path is the R2 bucket itself behind a custom domain, not a
          # server. Nothing we run has to be up for a substitution to succeed,
          # which is the entire reason niks3 replaced attic: atticd sat in the
          # read path, and every time can-1 ran out of memory three tier-1
          # hosts stopped being deployable under `max-jobs = 0`.
          "https://cache.arsfeld.dev"
          # attic is frozen — CI no longer pushes to it — but still serves
          # every path it already holds, which keeps the cold-cache window
          # short while R2 fills. Dropped when attic is retired.
          "https://attic.arsfeld.dev/system"
        ];
        trusted-public-keys = lib.mkAfter [
          "cache.arsfeld.dev-1:rf7PgrG/BVE3llOcYdiP0hNqIvOSvIQoz7zoH1kt1d8="
          "system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc="
        ];
```

with:

```nix
        substituters = lib.mkAfter [
          # The read path is the R2 bucket itself behind a custom domain, not a
          # server. Nothing we run has to be up for a substitution to succeed,
          # which is the entire reason niks3 replaced attic: atticd sat in the
          # read path, and every time can-1 ran out of memory three tier-1
          # hosts stopped being deployable under `max-jobs = 0`.
          #
          # This is the only cache we operate. attic was retired on 2026-09-07;
          # there is no second endpoint to fall back to.
          "https://cache.arsfeld.dev"
        ];
        trusted-public-keys = lib.mkAfter [
          "cache.arsfeld.dev-1:rf7PgrG/BVE3llOcYdiP0hNqIvOSvIQoz7zoH1kt1d8="
        ];
```

Note the first comment paragraph is **kept** — it explains why the read path is a bucket rather than a server, which is still the operative design rationale.

- [ ] **Step 3: Edit `installer-iso.nix`**

Replace:

```nix
    extra-substituters = [
      "https://cache.arsfeld.dev"
      "https://attic.arsfeld.dev/system"
    ];
    extra-trusted-public-keys = [
      "cache.arsfeld.dev-1:rf7PgrG/BVE3llOcYdiP0hNqIvOSvIQoz7zoH1kt1d8="
      "system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc="
    ];
```

with:

```nix
    extra-substituters = [
      "https://cache.arsfeld.dev"
    ];
    extra-trusted-public-keys = [
      "cache.arsfeld.dev-1:rf7PgrG/BVE3llOcYdiP0hNqIvOSvIQoz7zoH1kt1d8="
    ];
```

- [ ] **Step 4: Verify no attic references remain in Nix config**

```bash
cd /home/arosenfeld/Code/nixos
grep -rn "attic" modules/ installer-iso.nix
```

Expected: **exactly two lines**, both comments in `common.nix` — line 53 (`# which is the entire reason niks3 replaced attic: atticd sat in the`) and line 57 (`# This is the only cache we operate. attic was retired on 2026-09-07;`). Both are prose, not configuration. `installer-iso.nix` must produce no output at all.

What matters is that no *substituter URL* or *key* survives, so check that directly:

```bash
grep -rn "attic.arsfeld.dev\|system:mUX40QMM" modules/ installer-iso.nix
```

Expected: **no output**.

- [ ] **Step 5: Verify the evaluated configuration**

```bash
cd /home/arosenfeld/Code/nixos
nix eval --raw .#nixosConfigurations.raider.config.nix.settings.substituters --apply 'builtins.concatStringsSep "\n"'
echo
nix eval --raw .#nixosConfigurations.raider.config.nix.settings.trusted-public-keys --apply 'builtins.concatStringsSep "\n"'
```

Expected: neither list contains `attic.arsfeld.dev` or `system:mUX40QMM`. `https://cache.arsfeld.dev` and `cache.arsfeld.dev-1:rf7PgrG/…` are both still present.

- [ ] **Step 6: Format**

```bash
cd /home/arosenfeld/Code/nixos
just fmt
git diff --stat
```

Expected: only `modules/constellation/common.nix` and `installer-iso.nix` modified. If `just fmt` touches other files, that is pre-existing drift — leave it out of this commit.

- [ ] **Step 7: Build one host to prove evaluation still works**

```bash
cd /home/arosenfeld/Code/nixos
nix build .#nixosConfigurations.raider.config.system.build.toplevel --no-link
```

Expected: completes without error.

- [ ] **Step 8: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add modules/constellation/common.nix installer-iso.nix
git commit -m "feat(modules): drop the attic substituter and its signing key

attic has been frozen since niks3 replaced it on 2026-08-21 and now holds
nothing cache.arsfeld.dev does not: 0 unique paths in a 60-path sample of
raider's live closure. Every narinfo in nix-cache is signed
cache.arsfeld.dev-1, so the system: key had no other user.

It was also a cost rather than a fallback — nix queries every substituter
for every path, and attic missed 58 of 60 at ~50ms each."
```

---

### Task 2: Remove attic from CI workflows

**Files:**
- Modify: `.github/workflows/build.yml:44,45` (matrix job) and `:117,118` (build job)
- Modify: `.github/workflows/installer-iso.yml:26,27`

**Interfaces:**
- Consumes: nothing from Task 1 (independent edit, same push).
- Produces: CI runners configured with `cache.arsfeld.dev` only. Task 4 gates on a green run.

- [ ] **Step 1: Edit both blocks in `.github/workflows/build.yml`**

The identical two-line pair appears **twice** — once in the `matrix` job (~line 44) and once in the per-host build job (~line 117). Change both. Replace:

```yaml
            extra-substituters = https://cache.arsfeld.dev https://attic.arsfeld.dev/system
            extra-trusted-public-keys = cache.arsfeld.dev-1:rf7PgrG/BVE3llOcYdiP0hNqIvOSvIQoz7zoH1kt1d8= system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc=
```

with:

```yaml
            extra-substituters = https://cache.arsfeld.dev
            extra-trusted-public-keys = cache.arsfeld.dev-1:rf7PgrG/BVE3llOcYdiP0hNqIvOSvIQoz7zoH1kt1d8=
```

- [ ] **Step 2: Edit `.github/workflows/installer-iso.yml`**

Same replacement, one occurrence (~line 26).

- [ ] **Step 3: Verify all three are gone**

```bash
cd /home/arosenfeld/Code/nixos
grep -rn "attic" .github/
```

Expected: exactly one line of output —

```
.github/workflows/build.yml:162:          # keeps the exact shape the attic push had — an explicit command, a
```

That comment stays: it explains why the niks3 push step is written as an explicit command with a hard `::error::` exit rather than using `Mic92/niks3-action@v1`.

- [ ] **Step 4: Verify the YAML still parses**

```bash
cd /home/arosenfeld/Code/nixos
for f in .github/workflows/build.yml .github/workflows/installer-iso.yml; do
  python3 -c "import yaml,sys; yaml.safe_load(open('$f')); print('$f OK')"
done
```

Expected: two `OK` lines.

- [ ] **Step 5: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add .github/workflows/build.yml .github/workflows/installer-iso.yml
git commit -m "ci(modules): drop the attic substituter from CI runners

Three call sites: build.yml's matrix and per-host build jobs, and
installer-iso.yml. Runners now resolve against cache.arsfeld.dev alone."
```

---

### Task 3: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md:144-152` (the rollback paragraph)
- Modify: `CLAUDE.md:173-174` (managed resource counts)

**Interfaces:**
- Consumes: nothing.
- Produces: documentation matching post-retirement reality. The resource-count edit anticipates Task 8's DNS removal — the two must land before the next reader trusts either number.

- [ ] **Step 1: Replace the rollback paragraph**

Replace this exact paragraph (currently `CLAUDE.md:144-152`):

```
attic (`attic.arsfeld.dev`, k3s on can-1) is frozen but still running, and both it and its
key are still listed, so it remains the rollback. Restoring the **read** path needs no
revert at all — `attic.arsfeld.dev/system` is already a substituter on every host. Restoring
**pushes** takes two edits, not one: revert `82e84de` (the `build.yml` push step) *and* put
`attic-client` back in `flake-modules/dev.nix`, because that step runs under `nix develop`
and the client was removed separately in `acc7dad`. Reverting only the workflow gives
`attic: command not found` — which fails safe, since a red job makes weekly-deploy's tier-1
gate skip the commit, but it does not actually restore pushes. Retiring attic — the argocd
app, the `attic-cache` bucket, the `ATTIC_TOKEN` secret — is a separate later change.
```

with:

```
attic is being retired. It was the binary cache until niks3 replaced it on 2026-08-21
(`60dc149`, `194bfe3`), then sat frozen as a read-only fallback. As of 2026-09-07 its
substituter and `system:` key are gone from every host and from CI, so nothing resolves
against it any more. Still standing, pending the remaining steps of
`docs/superpowers/plans/2026-09-06-attic-retirement.md`: the `attic.arsfeld.dev` DNS
records, the argocd app and namespace on can-1, the `ATTIC_TOKEN` secret, and the R2
buckets `attic`, `attic-data` and `attic-cache`.

The measurement that justified it: of 60 paths sampled at random from raider's live
closure, `cache.arsfeld.dev` held 60 and attic held 2 — **zero** that attic had and R2
did not. Every narinfo in `nix-cache` is signed `cache.arsfeld.dev-1`, so nothing anywhere
depended on attic's key. Full workings in
`docs/superpowers/specs/2026-09-06-attic-retirement-design.md`.

**There is no fallback binary cache any more.** A path missing from `cache.arsfeld.dev`
falls through to `cache.nixos.org` and then to a local rebuild. That is harmless
everywhere except `weekly-deploy`, which runs under `max-jobs = 0` where a miss is a hard
failure — which is exactly what CI's `niks3 push --pin <host>` exists to prevent. Treat
the pins as load-bearing, not as an optimization.
```

- [ ] **Step 2: Leave the managed resource counts alone**

`CLAUDE.md:173-174` currently reads `56 resources … 50 cloudflare_dns_record`, which is
correct right now — the four attic records are still under management. They leave in
**Task 8**, and Task 8 changes this line in the same commit that destroys them.

Do not edit those numbers here. Documentation that runs ahead of the infrastructure it
describes is what this step used to do, and it made `CLAUDE.md` disagree with
`just tf state list` for the whole middle of the plan.

- [ ] **Step 3: Verify remaining attic references are only the intended ones**

`CLAUDE.md` now narrates the retirement, so it mentions attic many times by design. Check the *code* instead:

```bash
cd /home/arosenfeld/Code/nixos
grep -rn "attic" justfile hosts/ modules/
```

Expected exactly these seven, all deliberate design rationale (per the spec's "What stays, and why"):

```
justfile:72:    # Unlike the attic push this replaces, upload failures DO fold into
hosts/raider/configuration.nix:43:  # regression: raider already held an attic write token in
hosts/raider/configuration.nix:44:  # ~/.config/attic/config.toml.
hosts/basestar/services/niks3.nix:9:# That split is the whole point of replacing attic. atticd terminated uploads,
hosts/basestar/services/niks3.nix:55:    # 30 days, not attic's 6 months, because CI pins the tier-1 closures. The
modules/constellation/common.nix:53:          # which is the entire reason niks3 replaced attic: atticd sat in the
modules/constellation/common.nix:57:          # This is the only cache we operate. attic was retired on 2026-09-07;
```

Note `raider:43` and `raider:44` are one wrapped comment, and both `common.nix` lines are prose the retirement itself introduced or preserved. None asserts attic is reachable.

Counting comment lines by eye is what made two earlier versions of this step wrong. The check that actually matters is that no *functional* reference survives — assert that directly rather than trusting the line count:

```bash
grep -rn "attic\.arsfeld\.dev\|system:mUX40QMM" justfile hosts/ modules/ .github/ installer-iso.nix
```

Expected: **no output**.

Then confirm `CLAUDE.md` no longer claims attic is reachable:

```bash
grep -n "attic" CLAUDE.md | grep -iE "substituter|rollback|still (running|serves)|is frozen"
```

Expected: **no output**.

The rule: delete anything asserting attic is *currently available*; keep anything explaining *why a decision was made*.

- [ ] **Step 4: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add CLAUDE.md
git commit -m "docs(modules): record attic's retirement and correct resource counts

Replaces the rollback paragraph, which described a fallback that no longer
exists, with what actually happened and the measurement behind it. Also
drops the managed-resource counts to 52/46 ahead of the DNS removal."
```

---

### Task 4: Push and gate on CI

**Files:** none modified.

**Interfaces:**
- Consumes: commits from Tasks 1-3.
- Produces: a green `build.yml` run whose closures are pushed to niks3 with `--pin <host>`. Task 5's deploy substitutes from exactly those closures.

- [ ] **Step 1: Confirm the remote and what will be pushed**

```bash
cd /home/arosenfeld/Code/nixos
git remote -v
git log --oneline origin/master..master
```

Expected: `origin` is `github.com/arsfeld/nixos` (the push target — `forgejo` is stale and has no mirror). Exactly four commits ahead: the spec commit `518da4c` plus Tasks 1-3.

- [ ] **Step 2: Push**

```bash
cd /home/arosenfeld/Code/nixos
git push origin master
```

- [ ] **Step 3: Watch the build**

```bash
cd /home/arosenfeld/Code/nixos
gh run watch "$(gh run list --workflow=build.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

**GATE — do not proceed until this run is green.** All nine hosts must build and push. A red run means `weekly-deploy`'s tier-1 gate will skip this commit, so every later phase would be tearing down infrastructure the fleet has not yet moved off.

- [ ] **Step 4: Confirm the tier-1 closures reached niks3**

```bash
cd /home/arosenfeld/Code/nixos
for host in galactica basestar raider; do
  p=$(nix eval --raw ".#nixosConfigurations.$host.config.system.build.toplevel.outPath")
  h=$(basename "$p" | cut -d- -f1)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://cache.arsfeld.dev/$h.narinfo")
  echo "$host: $code $([ "$code" = 200 ] && echo 'in cache' || echo 'MISSING')"
done
```

Expected: three `200 in cache` lines. A `MISSING` here means the push did not land and Task 5 would deploy a closure the host cannot substitute.

---

### Task 5: Deploy tier-1 and verify substitution

**Files:** none modified.

**Interfaces:**
- Consumes: the green CI run from Task 4.
- Produces: three live hosts running without attic in `/etc/nix/nix.conf`. This is the gate every irreversible task depends on.

- [ ] **Step 1: Confirm you are on raider**

```bash
hostname
```

Expected: `raider`. `just deploy` phase 1 aborts from anywhere else with `auth token is required …`, an error that names niks3 rather than the real cause.

- [ ] **Step 2: Dry-run first**

```bash
cd /home/arosenfeld/Code/nixos
just dry-run @tier1
```

Expected: builds all three, then reports which units would change. Nix-config-only changes should show little or nothing restarting beyond `nix-daemon`.

- [ ] **Step 3: Deploy**

```bash
cd /home/arosenfeld/Code/nixos
just deploy @tier1
```

Expected: phase 1 builds and pushes all three; phase 2 activates each in parallel. Watch for `substituting`/`copying path` lines showing hosts pulling from `cache.arsfeld.dev`.

- [ ] **Step 4: Verify attic is gone from every tier-1 host's nix.conf**

```bash
for h in galactica basestar; do
  echo "=== $h ==="
  ssh "root@$h.bat-boa.ts.net" 'grep -E "^(substituters|trusted-public-keys)" /etc/nix/nix.conf'
done
echo "=== raider ==="
grep -E "^(substituters|trusted-public-keys)" /etc/nix/nix.conf
```

Expected: no line contains `attic.arsfeld.dev` or `system:mUX40QMM` on any of the three.

- [ ] **Step 5: Re-run the Task 1 baseline against the same 60 paths**

```bash
cd "$CLAUDE_JOB_DIR/tmp"
hits=0
while read -r p; do
  h=$(basename "$p" | cut -d- -f1)
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://cache.arsfeld.dev/$h.narinfo")" = 200 ] && hits=$((hits+1))
done < sample.txt
echo "cache.arsfeld.dev: $hits/60"
```

Expected: `60/60`, unchanged from Task 1 Step 1.

- [ ] **Step 6: Prove a real substitution works with attic absent**

On galactica, force a fetch of a path from the cache:

```bash
ssh root@galactica.bat-boa.ts.net \
  'nix path-info --store https://cache.arsfeld.dev $(readlink -f /run/current-system) >/dev/null && echo "substitution OK"'
```

Expected: `substitution OK`.

**GATE — everything from Task 6 onward is irreversible. Do not proceed unless Steps 4-6 all pass.**

---

### Task 6: Extract the R2 credential and inspect the bucket

**Files:**
- Create: `$CLAUDE_JOB_DIR/tmp/attic-r2.env` (scratch only — never commit)

**Interfaces:**
- Consumes: nothing from earlier tasks; requires the cluster to still be running.
- Produces: `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` with access to `attic-cache`, consumed by Task 9. **This must happen before Task 7 deletes the namespace holding the secret.**

- [ ] **Step 1: Confirm cluster context and that attic is still up**

```bash
kubectl config current-context
kubectl -n attic get pods
```

Expected: context `k3s-can1`; two Running pods, `attic-*` and `attic-postgres-*`.

- [ ] **Step 2: Extract the credential to scratch**

```bash
mkdir -p "$CLAUDE_JOB_DIR/tmp"
umask 077
cat > "$CLAUDE_JOB_DIR/tmp/attic-r2.env" <<EOF
export AWS_ACCESS_KEY_ID=$(kubectl -n attic get secret attic-secrets -o jsonpath='{.data.r2-access-key-id}' | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(kubectl -n attic get secret attic-secrets -o jsonpath='{.data.r2-secret-access-key}' | base64 -d)
export AWS_DEFAULT_REGION=auto
export R2_ENDPOINT=https://67a60cd5057ea97341c77d16f7cd3100.r2.cloudflarestorage.com
EOF
grep -c '^export' "$CLAUDE_JOB_DIR/tmp/attic-r2.env"
```

Expected: `4`. The secret's four keys are `db-password`, `jwt-secret-base64`, `r2-access-key-id`, `r2-secret-access-key`; only the last two are needed.

- [ ] **Step 3: Confirm the credential reaches the bucket**

```bash
source "$CLAUDE_JOB_DIR/tmp/attic-r2.env"
aws s3api head-bucket --endpoint-url "$R2_ENDPOINT" --bucket attic-cache && echo "access OK"
```

Expected: `access OK`. If this fails, **stop** — Task 9 cannot empty the bucket and tearing down the cluster in Task 7 would strand the only credential that can.

- [ ] **Step 4: Inspect what is actually in the bucket**

```bash
source "$CLAUDE_JOB_DIR/tmp/attic-r2.env"
aws s3api list-objects-v2 --endpoint-url "$R2_ENDPOINT" --bucket attic-cache \
  --max-items 20 --query 'Contents[].[Key,Size]' --output table
```

**GATE — a human reads this listing and confirms it is attic NAR chunks and nothing else.**

This step exists because the contents could not be verified during design: `secrets/sops/infra.yaml`'s R2 credentials are correctly scoped to `tfstate` alone, so only the object count (34,984), total size (48.5 GiB) and the absence of any public read path could be established. This is the one look anybody gets before 48.5 GiB is deleted. Do not automate past it.

- [ ] **Step 5: Record the object count for Task 9's comparison**

```bash
source "$CLAUDE_JOB_DIR/tmp/attic-r2.env"
aws s3api list-objects-v2 --endpoint-url "$R2_ENDPOINT" --bucket attic-cache \
  --query 'length(Contents)' --output text | tee "$CLAUDE_JOB_DIR/tmp/attic-cache-count.txt"
```

Expected: a number near 34,984. (`list-objects-v2` pages at 1000 by default; if the CLI reports only 1000, use `--page-size 1000` with pagination or accept the R2 analytics figure of 34,984 as the reference.)

---

### Task 7: Tear down the cluster app and delete the CI secret

**Files:**
- Delete: `apps/attic.yaml`, `manifests/attic/` (6 files) in `/home/arosenfeld/Code/argocd`
- Modify: `/home/arosenfeld/Code/argocd/.sops.yaml`
- Delete: `/home/arosenfeld/Code/argocd/scripts/attic-r2-cleanup.sh` (untracked local file)

**Interfaces:**
- Consumes: the credential extracted in Task 6 (already on disk — this task destroys its source).
- Produces: no atticd anywhere. Task 8 removes the DNS name that pointed at it.

- [ ] **Step 1: Confirm the credential is safely on disk first**

```bash
test -s "$CLAUDE_JOB_DIR/tmp/attic-r2.env" && echo "credential present" || echo "STOP — re-run Task 6"
```

Expected: `credential present`. If not, go back to Task 6 — after this task the secret is gone.

- [ ] **Step 2: Delete the ArgoCD Application**

```bash
kubectl -n argocd delete application attic
```

The Application has **no finalizers**, so this deletion is *non-cascading* — it removes the Application object and stops ArgoCD's `selfHeal`/`prune` reconciliation, but leaves the namespace and its workloads running. That is why Step 3 is separate and required.

- [ ] **Step 3: Delete the namespace and everything in it**

```bash
kubectl delete namespace attic
kubectl get namespace attic 2>&1 | head -2
```

Expected: the namespace terminates, then `Error from server (NotFound): namespaces "attic" not found`.

This removes the `attic` and `attic-postgres` deployments, the `attic-secrets` and `attic-tls` secrets, and the 5Gi `attic-postgres-data` PVC (storageclass `local-path`).

- [ ] **Step 4: Confirm the endpoint is actually dead**

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 https://attic.arsfeld.dev/system/nix-cache-info
```

Expected: anything other than `200` — a connection error, `502`, or `503`. Before teardown this returned `200` with `Priority: 41`.

- [ ] **Step 5: Delete the GitHub secret**

```bash
cd /home/arosenfeld/Code/nixos
gh secret delete ATTIC_TOKEN
gh secret list
```

Expected: `ATTIC_TOKEN` absent; `CLAUDE_CODE_OAUTH_TOKEN`, `NTFY_BASIC_AUTH_B64`, `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET` remain.

- [ ] **Step 6: Remove attic from the argocd repo**

Stage only these paths — the repo has unrelated uncommitted work (`apps/example-app.yaml` deleted, `backlog/config.yml` modified, untracked `backlog/tasks/` and `manifests/cert-manager/cloudflare-secret.yaml.new`). **Do not use `git add -A` or `git commit -a`.**

```bash
cd /home/arosenfeld/Code/argocd
rm -f scripts/attic-r2-cleanup.sh          # untracked; rm, not git rm
git rm -q apps/attic.yaml
git rm -q -r manifests/attic
```

Then edit `.sops.yaml` to remove this creation rule:

```yaml
  - path_regex: manifests/attic/.*-secret\.yaml$
    age: age1zmev49pzr0wxqdw4m5t5pk0ma98dchmxlucl0u6w2ajj762624qq7v3u43
```

leaving the `manifests/auth/`, `manifests/external-dns/`, `manifests/cert-manager/` and `.*\.enc\.yaml$` rules untouched.

- [ ] **Step 7: Verify the staged change is exactly attic**

```bash
cd /home/arosenfeld/Code/argocd
git status --porcelain
git diff --cached --stat
```

Expected in `--cached`: `apps/attic.yaml` and the 6 files under `manifests/attic/` deleted, nothing else. `apps/example-app.yaml`, `backlog/`, and `manifests/cert-manager/cloudflare-secret.yaml.new` must remain **unstaged**.

- [ ] **Step 8: Commit**

```bash
cd /home/arosenfeld/Code/argocd
git add .sops.yaml
git commit -m "chore(attic): remove the retired attic deployment

attic was replaced by niks3 on 2026-08-21 and retired on 2026-09-07 after
measuring zero unique paths against cache.arsfeld.dev. Application and
namespace already deleted from k3s-can1; this removes the manifests, the
sops creation rule and the R2 cleanup script."
git push origin HEAD
```

---

### Task 8: Remove the DNS records

**Files:**
- Modify: `infra/dns/arsfeld-dev.nix` — delete 4 resource blocks (lines 19-26, 105-125), 4 `import` blocks (lines 196-199, 236-247), and fix the comment at lines 100-104

**Interfaces:**
- Consumes: a torn-down server (Task 7) — deleting DNS first would only have made it unreachable.
- Produces: 46 `cloudflare_dns_record` resources in state, matching the count Task 3 wrote into CLAUDE.md.

- [ ] **Step 1: Delete the A record resource**

Remove this block from the `resource.cloudflare_dns_record` attrset:

```nix
    a_attic_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "attic.arsfeld.dev";
      type = "A";
      content = "149.56.129.39";
      ttl = 1;
      proxied = false;
    };
```

- [ ] **Step 2: Fix the ACME leftover comment**

Replace:

```nix
    # The eleven _acme-challenge TXT records below (attic, metadata-relay,
    # sumwhere, plane, windmill) are DNS-01 leftovers a client failed to
    # clean up after issuance. Adopted as found, per the import-only rule —
    # they're safe to delete out of band and drop from this file whenever
    # someone gets around to it.
```

with:

```nix
    # The eight _acme-challenge TXT records below (metadata-relay, sumwhere,
    # plane, windmill) are DNS-01 leftovers a client failed to clean up after
    # issuance. Adopted as found, per the import-only rule — they're safe to
    # delete out of band and drop from this file whenever someone gets around
    # to it. attic's three went with attic on 2026-09-07.
```

The remaining eight are metadata_relay (4), sumwhere (2), plane (1), windmill (1) — verified by counting resource blocks, not inferred from a plan summary.

- [ ] **Step 3: Delete the three TXT resource blocks**

```nix
    txt__acme_challenge_attic_arsfeld_dev_1 = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "_acme-challenge.attic.arsfeld.dev";
      type = "TXT";
      content = "-5ozHdDgqhtwl9ZpbejET2UogakOd4893LrYByEglJ8";
      ttl = 120;
    };
    txt__acme_challenge_attic_arsfeld_dev_2 = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "_acme-challenge.attic.arsfeld.dev";
      type = "TXT";
      content = "AnvqNKq1sWCvaza0E_HwZQFwrJIWGAPTKbrxhduPv3w";
      ttl = 120;
    };
    txt__acme_challenge_attic_arsfeld_dev_3 = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "_acme-challenge.attic.arsfeld.dev";
      type = "TXT";
      content = "thrtLJvkAulF8v8mw9Zicu5E__ofaEvc2QP2BXY2OhQ";
      ttl = 120;
    };
```

- [ ] **Step 4: Delete the four matching `import` blocks**

An `import` block referencing a resource with no configuration is an error, so these must go with them:

```nix
    {
      to = "cloudflare_dns_record.a_attic_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/e6337d3ced84f47f6e0aa3f5297b9185";
    }
```

```nix
    {
      to = "cloudflare_dns_record.txt__acme_challenge_attic_arsfeld_dev_1";
      id = "5b658a2265b2562c6f51ac93de8d21bf/3b9cde6d018b635e6c7e9e27f2a0e9fb";
    }
    {
      to = "cloudflare_dns_record.txt__acme_challenge_attic_arsfeld_dev_2";
      id = "5b658a2265b2562c6f51ac93de8d21bf/d37a6a5b358742855ea4f020065bc436";
    }
    {
      to = "cloudflare_dns_record.txt__acme_challenge_attic_arsfeld_dev_3";
      id = "5b658a2265b2562c6f51ac93de8d21bf/c2b2d93c1855a7af15e7670a31ea2a4a";
    }
```

- [ ] **Step 5: Verify the file is clean and formatted**

```bash
cd /home/arosenfeld/Code/nixos
grep -n "attic" infra/dns/arsfeld-dev.nix
just fmt
grep -cE "^    [a-z0-9_]+ = \{" infra/dns/arsfeld-dev.nix
```

Expected: the `grep` for attic prints **only** the comment line added in Step 2 (`# to it. attic's three went with attic on 2026-09-07.`); the resource count prints **19** (was 23).

- [ ] **Step 6: Plan, and read what it names**

```bash
cd /home/arosenfeld/Code/nixos
just tf plan
```

**GATE — read the resource names, not the summary line.** Expected: `Plan: 0 to add, 0 to change, 4 to destroy`, and the four named must be exactly `cloudflare_dns_record.a_attic_arsfeld_dev` and `cloudflare_dns_record.txt__acme_challenge_attic_arsfeld_dev_{1,2,3}`.

If the plan names anything else — an OCI resource, another DNS record — **stop**. Per CLAUDE.md, committing to `infra/` stages a real change for whoever applies next, and this has already caused an unrelated task to push someone else's edit live. A clean count is not proof of a clean plan.

- [ ] **Step 7: Apply**

```bash
cd /home/arosenfeld/Code/nixos
just tf apply
```

Expected: `Destroy complete! Resources: 4 destroyed.`

Apply **before** committing so nothing is left staged for another operator.

- [ ] **Step 8: Verify state and DNS**

```bash
cd /home/arosenfeld/Code/nixos
just tf state list | grep -c "^cloudflare_dns_record\."
```

Expected: `46`.

Then confirm the records are gone **via the Cloudflare API, not dig**:

```bash
# expect atticRecordCount 0
curl -s "https://api.cloudflare.com/client/v4/zones/5b658a2265b2562c6f51ac93de8d21bf/dns_records?per_page=200" \
  -H "Authorization: Bearer $CF_TOKEN" | jq '[.result[] | select(.name|test("attic"))] | length'
```

`dig` cannot answer this question. The zone has a proxied `*.arsfeld.dev` wildcard
CNAME, so `dig +short attic.arsfeld.dev` returns a Cloudflare address whether or not
attic has a record of its own. Count records in the zone instead.

- [ ] **Step 9: Update the managed resource counts**

Now that the records are actually gone, `CLAUDE.md:173-174` becomes true. Replace:

```
`infra/`, written as terranix Nix modules rather than HCL. 56 resources are
under management: 50 `cloudflare_dns_record` plus 6 Oracle resources (VCN,
```

with:

```
`infra/`, written as terranix Nix modules rather than HCL. 52 resources are
under management: 46 `cloudflare_dns_record` plus 6 Oracle resources (VCN,
```

Step 8 has already confirmed `just tf state list` reports 46, so this documents
verified reality rather than an intention.

- [ ] **Step 10: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add infra/dns/arsfeld-dev.nix CLAUDE.md
git commit -m "chore(modules): remove attic's DNS records

The A record for attic.arsfeld.dev and three _acme-challenge TXT leftovers,
with their import blocks. Applied before committing so nothing is left
staged. 50 managed DNS records becomes 46, in CLAUDE.md too."
git push origin master
```

---

### Task 9: Delete the R2 buckets

**Files:** none in any repo.

**Interfaces:**
- Consumes: the credential from Task 6 and the human sign-off from Task 6 Step 4.
- Produces: four remaining buckets in the account.

- [ ] **Step 1: Re-confirm nothing reads these buckets**

```bash
cd /home/arosenfeld/Code/nixos
for b in attic attic-data attic-cache; do
  echo "=== $b ==="
  curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/67a60cd5057ea97341c77d16f7cd3100/r2/buckets/$b/domains/custom" \
    -H "Authorization: Bearer $(nix develop -c sops --decrypt secrets/sops/infra.yaml | grep '^TF_VAR_cloudflare_api_token:' | cut -d' ' -f2)" \
    | jq -c '.result'
done
```

Expected: `{"domains":[]}` for all three. (This can also be read from the Cloudflare dashboard; the point is that no custom domain and no enabled `r2.dev` domain means nothing but atticd's credential ever reached them, and atticd is gone as of Task 7.)

- [ ] **Step 2: Empty `attic-cache`**

`attic` and `attic-data` are already at 0 objects — each carries a `delete all` lifecycle rule at `maxAge` 86400 that drained them long ago. Only `attic-cache` has content.

```bash
source "$CLAUDE_JOB_DIR/tmp/attic-r2.env"
aws s3 rm "s3://attic-cache" --recursive --endpoint-url "$R2_ENDPOINT" --only-show-errors
```

Expected: no output (errors only). This deletes ~34,984 objects / 48.5 GiB and takes several minutes.

- [ ] **Step 3: Confirm it is empty**

```bash
source "$CLAUDE_JOB_DIR/tmp/attic-r2.env"
aws s3api list-objects-v2 --endpoint-url "$R2_ENDPOINT" --bucket attic-cache --max-items 5 --query 'Contents' --output text
```

Expected: `None`. R2 refuses to delete a non-empty bucket, so this must pass before Step 4.

- [ ] **Step 4: Delete all three buckets**

`attic` and `attic-data` need no S3 credential — they are already empty.

```bash
cd /home/arosenfeld/Code/nixos
CF_TOKEN=$(nix develop -c sops --decrypt secrets/sops/infra.yaml | grep '^TF_VAR_cloudflare_api_token:' | cut -d' ' -f2)
for b in attic attic-data attic-cache; do
  echo -n "$b: "
  curl -s -X DELETE \
    "https://api.cloudflare.com/client/v4/accounts/67a60cd5057ea97341c77d16f7cd3100/r2/buckets/$b" \
    -H "Authorization: Bearer $CF_TOKEN" | jq -c '{success, errors}'
done
unset CF_TOKEN
```

Expected: `{"success":true,"errors":[]}` three times. A `success:false` naming a non-empty bucket means Step 2 did not finish — re-run it.

If the `TF_VAR_cloudflare_api_token` lacks R2 admin scope (it is provisioned for DNS), delete the three buckets from the Cloudflare dashboard instead: **R2 → the bucket → Settings → Delete bucket**.

- [ ] **Step 5: Verify the account**

```bash
cd /home/arosenfeld/Code/nixos
CF_TOKEN=$(nix develop -c sops --decrypt secrets/sops/infra.yaml | grep '^TF_VAR_cloudflare_api_token:' | cut -d' ' -f2)
curl -s "https://api.cloudflare.com/client/v4/accounts/67a60cd5057ea97341c77d16f7cd3100/r2/buckets" \
  -H "Authorization: Bearer $CF_TOKEN" | jq -r '.result.buckets[].name' | sort
unset CF_TOKEN
```

Expected exactly four lines: `mydia-flatpak`, `nix-cache`, `tfstate`, `whatsrev`.

- [ ] **Step 6: Destroy the scratch credential**

```bash
shred -u "$CLAUDE_JOB_DIR/tmp/attic-r2.env" 2>/dev/null || rm -f "$CLAUDE_JOB_DIR/tmp/attic-r2.env"
test -f "$CLAUDE_JOB_DIR/tmp/attic-r2.env" && echo "STILL PRESENT" || echo "removed"
```

Expected: `removed`. The R2 credential it held is now useless (its buckets are gone), but it should not linger on disk.

---

### Task 10: Local cleanup and final verification

**Files:**
- Delete: `~/.config/attic/` and `~/.local/share/attic/` on raider

**Interfaces:**
- Consumes: completion of Tasks 1-9.
- Produces: nothing downstream; this is the closing sweep.

- [ ] **Step 1: Remove the stale attic client credential**

`~/.config/attic/config.toml` holds a write token for a server that no longer exists — dead credential hygiene rather than a live risk. `~/.local/share/attic/` holds `server.db` and a `storage/` directory from a local atticd experiment.

```bash
ls -la ~/.config/attic/ ~/.local/share/attic/
rm -rf ~/.config/attic ~/.local/share/attic
ls ~/.config/attic ~/.local/share/attic 2>&1
```

Expected: two `No such file or directory` lines.

- [ ] **Step 2: Full-repo sweep for anything missed**

```bash
cd /home/arosenfeld/Code/nixos
grep -rn "attic" --exclude-dir=.git --exclude-dir=docs --exclude-dir=blog --exclude=CLAUDE.md .
```

Expected exactly these nine lines, all deliberate:

```
justfile:72:    # Unlike the attic push this replaces, upload failures DO fold into
.github/workflows/build.yml:162:          # keeps the exact shape the attic push had ...
hosts/raider/configuration.nix:43:  # regression: raider already held an attic write token in
hosts/raider/configuration.nix:44:  # ~/.config/attic/config.toml.
hosts/basestar/services/niks3.nix:9:# That split is the whole point of replacing attic ...
hosts/basestar/services/niks3.nix:55:    # 30 days, not attic's 6 months ...
modules/constellation/common.nix:53:          # which is the entire reason niks3 replaced attic: atticd sat in the
modules/constellation/common.nix:57:          # This is the only cache we operate. attic was retired on 2026-09-07;
infra/dns/arsfeld-dev.nix:104:    # to it. attic's three went with attic on 2026-09-07.
```

(The `infra/dns` line number shifts as records are removed; match the text, not the number. `raider:43`/`:44` are one wrapped comment.)

As in Task 3, the line count is the weak check. The one that matters:

```bash
cd /home/arosenfeld/Code/nixos
grep -rn "attic\.arsfeld\.dev\|system:mUX40QMM" \
  --exclude-dir=.git --exclude-dir=docs --exclude-dir=blog --exclude=CLAUDE.md .
```

Expected: **no output** — no surviving substituter URL or signing key in any configuration.

`CLAUDE.md` is excluded because its retirement paragraph names `attic.arsfeld.dev` in
prose, deliberately, to explain why the hostname still resolves through the wildcard.
Checking prose and checking configuration are different jobs; conflating them is what
made three earlier versions of these sweeps assert impossible output.

`CLAUDE.md` is excluded because it now narrates the retirement — checked separately in Task 3 Step 3. `docs/` and `blog/` are excluded on purpose: they are a historical record and should not be rewritten.

- [ ] **Step 3: End-to-end verification**

```bash
echo "--- attic must be gone ---"
# NOT dig: the proxied *.arsfeld.dev wildcard answers for any name.
# attic is gone when the zone holds zero records matching "attic", and when
# the response body carries no StoreDir. Both of these must hold:
curl -s --max-time 15 https://attic.arsfeld.dev/system/nix-cache-info | grep -q StoreDir \
  && echo "STILL A CACHE — bad" || echo "not a cache — correct"

echo "--- cache must be healthy ---"
curl -s --max-time 10 https://cache.arsfeld.dev/nix-cache-info
curl -s -o /dev/null -w 'niks3: %{http_code}\n' --max-time 10 https://niks3.arsfeld.dev/

echo "--- tier-1 closures still substitutable ---"
cd /home/arosenfeld/Code/nixos
for host in galactica basestar raider; do
  p=$(nix eval --raw ".#nixosConfigurations.$host.config.system.build.toplevel.outPath")
  h=$(basename "$p" | cut -d- -f1)
  echo "$host: $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://cache.arsfeld.dev/$h.narinfo")"
done
```

Expected: empty `dig`; a non-200 for attic; `StoreDir: /nix/store … Priority: 30` from `cache.arsfeld.dev`; three `200`s for the tier-1 closures.

- [ ] **Step 4: Tighten CLAUDE.md to its final form**

Task 3 deliberately wrote a paragraph describing a retirement in progress, because at that
point it was. Everything it listed as "still standing" is now gone, so replace:

```
attic is being retired. It was the binary cache until niks3 replaced it on 2026-08-21
(`60dc149`, `194bfe3`), then sat frozen as a read-only fallback. As of 2026-09-07 its
substituter and `system:` key are gone from every host and from CI, so nothing resolves
against it any more. Still standing, pending the remaining steps of
`docs/superpowers/plans/2026-09-06-attic-retirement.md`: the `attic.arsfeld.dev` DNS
records, the argocd app and namespace on can-1, the `ATTIC_TOKEN` secret, and the R2
buckets `attic`, `attic-data` and `attic-cache`.
```

with:

```
attic is gone. It was the binary cache until niks3 replaced it on 2026-08-21 (`60dc149`,
`194bfe3`), sat frozen as a read-only fallback for 17 days, and was retired entirely on
2026-09-07: substituter and `system:` key removed from every host and from CI, the argocd
app and namespace on can-1 torn down, the `ATTIC_TOKEN` secret deleted, all four
`attic.arsfeld.dev` DNS records removed, and the R2 buckets `attic`, `attic-data` and
`attic-cache` deleted.

`attic.arsfeld.dev` still *resolves*, and still answers HTTP 200, and both are expected:
the zone has a proxied `*.arsfeld.dev` wildcard CNAME, so the name falls through to it and
lands on the zone's catch-all. What comes back is an empty body with no `StoreDir`, which
is not a usable binary cache. Neither a successful `dig` nor a 200 is evidence attic
survived — check for a DNS record of its own, or for `StoreDir` in the response body.
```

Leave the two paragraphs that follow it unchanged — the measurement and the
"no fallback binary cache any more" warning are already true and stay true.

- [ ] **Step 5: Mark the spec implemented**

In `docs/superpowers/specs/2026-09-06-attic-retirement-design.md`, change:

```
**Status:** approved, not yet implemented
```

to:

```
**Status:** implemented 2026-09-07
```

```bash
cd /home/arosenfeld/Code/nixos
git add docs/superpowers/specs/2026-09-06-attic-retirement-design.md CLAUDE.md
git commit -m "docs(modules): mark the attic retirement complete"
git push origin master
```

- [ ] **Step 6: Watch the Sunday deploy**

The real end-to-end confirmation is `weekly-deploy` on **Sunday 2026-09-13 06:00 UTC** — the only path running under `max-jobs = 0`, where a cache miss is a hard failure rather than a local rebuild. Its ntfy summary is the signal.

To confirm early rather than waiting:

```bash
ssh root@galactica.bat-boa.ts.net 'systemctl start weekly-deploy && journalctl -u weekly-deploy -f'
```

Expected: all three hosts deploy with no build activity — `max-jobs = 0` means every path is substituted or the run fails.

---

## Notes for the implementer

**The one-way door is Task 7.** Tasks 1-5 are reversible with `git revert` plus a redeploy. From Task 7 the recovery is a rebuild, not a revert.

**Task 6 must precede Task 7.** The only credential that can empty `attic-cache` lives in the `attic-secrets` k8s secret inside the namespace Task 7 deletes. Reversing them strands 48.5 GiB with no way to remove it short of minting a new R2 token.

**Task 6 Step 4 is a human gate.** The bucket's contents could not be verified during design because the `infra.yaml` R2 credentials are correctly scoped to `tfstate` alone. That listing is the only look anyone gets before the data is destroyed.

**Task 8 Step 6 is a human gate.** Read the plan's named resources, not its summary line. CLAUDE.md documents a case where a clean-looking count hid a mismatch with reality for weeks.

**If a deploy fails after Task 7 with a missing path:** the closure was never pushed to niks3, which means CI was not green — the Task 4 gate was skipped. Re-run `build.yml` for that host, confirm the narinfo appears at `cache.arsfeld.dev`, then redeploy. Do not disable `max-jobs = 0`; it is what makes the failure visible instead of silent.
