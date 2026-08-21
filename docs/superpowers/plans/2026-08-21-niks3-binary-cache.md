# niks3 Binary Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `attic.arsfeld.dev` binary cache with niks3 — a coordinator that hands out presigned Cloudflare R2 URLs — so that no self-hosted machine sits in the read path of a fleet deploy.

**Architecture:** One endpoint becomes two. **Reads** go to `https://cache.arsfeld.dev`, the R2 bucket `nix-cache` with a custom domain attached; there is no server, so nothing of ours can make a substitution fail. **Writes** go to `https://niks3.arsfeld.dev`, niks3 running on basestar behind Caddy; clients ask it for presigned URLs, PUT NARs straight to R2, and the server only records references in PostgreSQL for GC. CI pins each tier-1 closure so the 30-day GC window can never delete the closure `weekly-deploy` needs under `max-jobs = 0`.

**Tech Stack:** Nix flakes / flake-parts, [niks3](https://github.com/Mic92/niks3) (NixOS modules `niks3` + `niks3-auto-upload`), Cloudflare R2, Caddy, sops-nix, `nix-fast-build`, GitHub Actions OIDC.

**Source spec:** `docs/superpowers/specs/2026-08-20-niks3-binary-cache-design.md`

---

## Global Constraints

- **Never branch.** Commit straight to `master`. No feature branches, no worktrees — a branch-only config gets reverted by the routine tier-1 deploy.
- **Conventional commits**: `<type>(<scope>): <subject>`. Scopes here: `basestar`, `raider`, `modules`, `secrets`, `ci`, `docs`. Never mention Claude in a commit message or author.
- **Format before committing**: `just fmt` (alejandra). `format.yml` fails CI on unformatted Nix.
- **Tasks 3–10 are committed locally but NOT pushed.** The first `git push` happens in Task 12, deliberately, after basestar is already running the server. Land this Monday–Thursday, never Friday or Saturday.
- **Cloudflare account ID**: `67a60cd5057ea97341c77d16f7cd3100`
- **R2 S3 endpoint**: `67a60cd5057ea97341c77d16f7cd3100.r2.cloudflarestorage.com`
- **R2 bucket**: `nix-cache` (new — never reuse `attic-cache`, whose chunk layout is incompatible)
- **Read URL**: `https://cache.arsfeld.dev` · **Write URL**: `https://niks3.arsfeld.dev`
- **basestar public IP**: `168.138.71.109`
- **`arsfeld.dev` zone id**: `5b658a2265b2562c6f51ac93de8d21bf` (verified via API 2026-08-21)
- **Signing key name**: `cache.arsfeld.dev-1`
- **`<CACHE_PUBKEY>`** = `cache.arsfeld.dev-1:rf7PgrG/BVE3llOcYdiP0hNqIvOSvIQoz7zoH1kt1d8=` (generated and verified 2026-08-21). It appears verbatim in Tasks 6, 8 and 12, and was originally the single line printed by Task 2 Step 3 (`cache.arsfeld.dev-1:<44-char-base64>`), recorded at `/tmp/niks3-cutover/cache-pubkey.txt`. Every occurrence of `<CACHE_PUBKEY>` in this plan means "paste that exact string".
- **Never decrypt a secret you are not changing.** Verify sops edits by key name and
  ciphertext stability, or by comparing sha256 digests — never by printing plaintext.
  Reports and terminal output are durable; an incidental `sops --decrypt` of an unrelated
  key leaks a live production credential into them. (This happened during Task 2 and cost
  a rotation; see the ledger.)
- **Never add an R2 lifecycle rule to `nix-cache`.** niks3's GC deletes objects from its own Postgres reference table; a lifecycle rule deleting them behind its back leaves narinfos pointing at absent NARs — a corrupted cache that fails only at deploy time.
- **Leave `maxNarSize` unset.** Multipart upload handles large closures. A cap makes clients silently skip store paths, reintroducing cache misses on hosts that deploy under `max-jobs = 0`, where a miss is a hard failure rather than a local rebuild.
- **Do not delete the argocd attic app or the `attic-cache` bucket** in this change. They cost $0.78/month and are the rollback.
- **The invariant that governs every deploy path** (from CLAUDE.md): every deploy path must evaluate `.#nixosConfigurations` and must never `import inputs.nixpkgs` to build its own package set. Nothing in this plan touches that; do not introduce a second evaluation.

## Deviations from the spec — read before starting

The spec was written against an assumed state of the tree. Five things differ, all decided:

1. **`just/deploy.just` does not exist.** The deploy driver landed in `justfile` itself (`_poke-targets`, `_hosts`, `_apply`, `deploy`, … lines 20–150). Task 7 edits `justfile`.
2. **`--attic-cache system` was never in the driver.** The landed `_apply` calls `attic push` separately and best-effort, with a comment explaining that `--attic-cache` was rejected because it folds upload failures into nix-fast-build's exit code. `--niks3-server` behaves identically (`nix_fast_build/workers.py:219` → `Result.success`). **Decision: use `--niks3-server` anyway, per the spec**, and delete the separate push. The rationale changes — see Task 7 — and CLAUDE.md must be rewritten to match, because it currently documents best-effort as deliberate.
3. **niks3 is added alongside attic as a substituter, not in place of it** (Tasks 6 and 8). attic is frozen — CI stops pushing to it — but keeps serving everything it already holds, which shortens the cold-cache window while R2 fills. attic drops out of the substituter list in the separate retire-attic change.
4. **`.github/workflows/update.yml` also needs `id-token: write`** (Task 8). This is not in the spec's change surface. A reusable workflow's `GITHUB_TOKEN` permissions can only be the same or more restrictive than the caller's, so without it the weekly update's `build` job cannot mint an OIDC token and every Sunday push fails.
5. **`ATTIC_TOKEN` is NOT deleted from GitHub secrets in this change.** The spec says to delete it; deferring it to the retire-attic change is what keeps `git revert` a working rollback. Task 15 records it as a follow-up.
6. **The spec contradicts itself about `~/.config/niks3/auth-token`.** Its nix-fast-build section says to provision that file on raider; its Secrets section says `NIKS3_AUTH_TOKEN_FILE` exists specifically to avoid a second copy of the token there. Resolution: no persistent second copy. `NIKS3_AUTH_TOKEN_FILE` is set from the sops secret (Task 5), and the one deploy that runs *before* that secret exists gets a temporary file that is shredded immediately after (Task 13 Steps 1 and 3).
8. **The R2 credential is freshly minted and scoped to `nix-cache`, not copied from attic** (user decision, 2026-08-21). This retires the spec's largest risk rather than carrying it: no shared credential between the old and new caches, and Task 15's rotation follow-up is satisfied up front. The cost is one manual dashboard step — verified unavoidable, since `/accounts/{id}/tokens` returns `9109 Unauthorized` for this session and the OpenAPI spec has no R2-specific token endpoint.
9. **Execution is resequenced.** Tasks 3–9 need nothing from Tasks 1–2 except `<CACHE_PUBKEY>`, which is generated locally with `nix key generate-secret` and needs no Cloudflare access at all. So Task 2's local half runs first, then Tasks 3–9, then Task 1's provisioning and Task 2's R2 half once the token exists, then 10–14 in order. The ledger records actual order.

7. **niks3 upstream has moved past the versions the spec names.** The spec cites the nixpkgs package at 1.6.0; the flake currently ships CLI 1.8.0 and server 1.4.0, and the module defaults `serverPackage` to its own `callPackage` so the two stay locked together. `go.mod` requires Go 1.25.7 and nixpkgs 26.05 ships 1.26.5, so both build. Nothing in this plan pins a version — `flake.lock` does.

## File Structure

| File | Responsibility |
|---|---|
| `flake.nix` | Add the `niks3` input. The NixOS modules are not in nixpkgs; only the package is. |
| `flake-modules/dev.nix` | Dev shell: swap `attic-client` for `niks3`. `nix-fast-build` resolves the `niks3` binary from `PATH` and otherwise falls back to an unpinned `nix shell github:Mic92/niks3`. |
| `hosts/basestar/services/niks3.nix` | **New.** The server: upstream module import, R2 wiring, OIDC, GC, sops secrets, Caddy vhost. One file, one service, following the `siyuan.nix` / `planka.nix` shape. |
| `hosts/basestar/services/default.nix` | Add `./niks3.nix` to imports. |
| `hosts/raider/configuration.nix` | Auto-upload daemon, its sops secret, and `NIKS3_AUTH_TOKEN_FILE` in the session env. |
| `secrets/sops/basestar.yaml` | `niks3-api-token`, `niks3-sign-key`, `r2-access-key-id`, `r2-secret-access-key`. |
| `secrets/sops/raider.yaml` | `niks3-api-token` (same value as basestar's). |
| `modules/constellation/common.nix` | Fleet-wide substituter + trusted key. |
| `installer-iso.nix` | Same, for the installer ISO's `nixos-install`. |
| `justfile` | `_apply` phase 1 pushes via `--niks3-server`; the `cache` recipe uses `niks3 push`. |
| `.github/workflows/build.yml` | Substituters, `id-token: write`, OIDC token script, pinned push. |
| `.github/workflows/update.yml` | `id-token: write` on the reusable-workflow call. |
| `.github/workflows/installer-iso.yml` | Substituter only (read path, no push). |
| `.github/workflows/fix-ci.yml` | The transient-failure example text names attic. |
| `modules/constellation/weekly-deploy.nix` | Two comments name attic. No behaviour change. |
| `CLAUDE.md`, `README.md`, `docs/guides/getting-started.md` | Prose. CLAUDE.md's Traefik `readTimeout` paragraph describes a constraint that ceases to exist. |

---

### Task 1: Mint the R2 credential and provision Cloudflare

The spec planned to reuse attic's R2 credential and gate on whether it was account-wide. That gate is gone: the credential is minted fresh and scoped to `nix-cache` instead (Deviation 8), which is strictly better — no shared credential with the cache being retired, and no dependency on reading a k8s secret out of can-1.

The one cost is that minting it is manual. `/accounts/{id}/tokens` returns `9109 Unauthorized` for the available session and the OpenAPI spec exposes no R2-specific token endpoint, both verified 2026-08-21. Everything else in this task is API-driven.

**Files:** none — this task changes no tracked files and produces no commit.

**Interfaces:**
- Consumes: nothing.
- Produces: R2 bucket `nix-cache`; a bucket-scoped R2 API token whose two halves land at `/tmp/niks3-cutover/r2-access-key-id.txt` and `/tmp/niks3-cutover/r2-secret-access-key.txt` for Task 2; a custom domain `cache.arsfeld.dev` bound to the bucket; a grey-cloud `A` record `niks3.arsfeld.dev → 168.138.71.109`.

- [ ] **Step 1: Create the scratch directory for cutover values**

These files hold live credentials. Create the directory mode `0700` and delete it in Task 14.

```bash
mkdir -m700 -p /tmp/niks3-cutover
```

- [ ] **Step 2: Create the bucket**

Do this before minting the token, so the token can be scoped to a bucket that exists. Use the Cloudflare API — this endpoint is permitted, unlike the token endpoint.

```
POST /accounts/67a60cd5057ea97341c77d16f7cd3100/r2/buckets
{"name": "nix-cache"}
```

Then confirm:

```
GET /accounts/67a60cd5057ea97341c77d16f7cd3100/r2/buckets
```

Expected: the bucket list now contains `nix-cache` alongside the existing `attic`, `attic-cache`, `attic-data`, `mydia-flatpak` and `whatsrev`. (`attic` and `attic-data` are the stale empty buckets from 2024 that Task 15 Step 2 sweeps up — leave them.)

- [ ] **Step 3: Have the human mint a bucket-scoped R2 token**

This is the one step that cannot be automated. Ask the user to visit **Cloudflare dashboard → R2 → API → Manage API tokens → Create API token** with:

- **Permission:** Object Read & Write
- **Specify bucket:** `nix-cache` only — not "all buckets". Scoping it here is what makes this better than reusing attic's credential.
- **TTL:** forever

The dashboard then shows an Access Key ID and a Secret Access Key **once**. Ask the user to write them into the scratch directory rather than pasting them into the conversation, so they never enter the transcript:

```bash
umask 077
printf %s '<access key id>'     > /tmp/niks3-cutover/r2-access-key-id.txt
printf %s '<secret access key>' > /tmp/niks3-cutover/r2-secret-access-key.txt
```

`printf %s` rather than `echo` avoids a trailing newline. (`niks3-server` trims whitespace when reading these files, so a newline would be tolerated anyway — but a stray quote would not.)

Wait for both files to exist and be non-empty before continuing:

```bash
wc -c /tmp/niks3-cutover/r2-access-key-id.txt /tmp/niks3-cutover/r2-secret-access-key.txt
```

Expected: roughly 32 bytes and 64 bytes respectively, neither zero.

- [ ] **Step 4: Prove the token can read and write the bucket**

This is the gate that replaces the spec's bucket-scope check: it verifies the freshly minted credential works against the exact bucket and endpoint niks3 will use.

```bash
export AWS_ACCESS_KEY_ID="$(cat /tmp/niks3-cutover/r2-access-key-id.txt)"
export AWS_SECRET_ACCESS_KEY="$(cat /tmp/niks3-cutover/r2-secret-access-key.txt)"
export AWS_DEFAULT_REGION=auto
export AWS_ENDPOINT_URL="https://67a60cd5057ea97341c77d16f7cd3100.r2.cloudflarestorage.com"

echo probe | nix shell nixpkgs#awscli2 -c aws s3 cp - s3://nix-cache/_probe.txt
nix shell nixpkgs#awscli2 -c aws s3 cp s3://nix-cache/_probe.txt -
nix shell nixpkgs#awscli2 -c aws s3 rm s3://nix-cache/_probe.txt
```

Expected: the middle command prints `probe`.

**If any of the three returns `AccessDenied`, STOP** and report to the user — the token's permission or bucket scope is wrong, and nothing downstream can work until it is reissued. Do not attempt to work around it.

- [ ] **Step 5: Attach the custom domain `cache.arsfeld.dev` to the bucket**

Attaching the domain is what makes objects publicly readable — there is no separate public-access toggle, and the managed `r2.dev` domain stays disabled. Use the Cloudflare API (the `cloudflare-api` MCP `execute` tool, or `curl` with an API token that has R2 Admin):

```
POST /accounts/67a60cd5057ea97341c77d16f7cd3100/r2/buckets/nix-cache/domains/custom
{"domain": "cache.arsfeld.dev", "enabled": true, "zoneId": "5b658a2265b2562c6f51ac93de8d21bf"}
```

Then confirm:

```
GET /accounts/67a60cd5057ea97341c77d16f7cd3100/r2/buckets/nix-cache/domains/custom
```

Expected: one entry, `"domain": "cache.arsfeld.dev"`, `"enabled": true`, status eventually `active`.

- [ ] **Step 6: Create the grey-cloud A record for the server**

```
POST /zones/5b658a2265b2562c6f51ac93de8d21bf/dns_records
{"type": "A", "name": "niks3", "content": "168.138.71.109", "proxied": false, "ttl": 1}
```

`"proxied": false` (grey-cloud) is **not optional**. Proxied records serve GitHub-hosted runners Cloudflare's managed challenge (HTTP 403) — the same reason CI can never post to `ntfy.arsfeld.one`. `attic.arsfeld.dev` and `seed.arsfeld.dev` are already DNS-only to this exact IP for this exact reason. The usual counter-argument (Cloudflare's 100 MB request body limit) does not apply, because NARs never traverse this hostname.

- [ ] **Step 7: Verify DNS resolves and is unproxied**

```bash
dig +short niks3.arsfeld.dev
dig +short cache.arsfeld.dev
```

Expected: `niks3.arsfeld.dev` → exactly `168.138.71.109` (a Cloudflare anycast address such as `104.x` or `172.67.x` means the record is still proxied — fix it before continuing). `cache.arsfeld.dev` → Cloudflare addresses, which is correct: that one *is* the edge in front of R2.

- [ ] **Step 8: Record what was provisioned**

No commit. Write a one-paragraph note in the session output naming the bucket, the custom domain status, and the token's scope. Task 15 Step 3's rotation follow-up is already satisfied if the token is scoped to `nix-cache` — say so explicitly there.

---

### Task 2: Generate and store the secrets

**Files:**
- Modify: `secrets/sops/basestar.yaml` (four new keys)
- Modify: `secrets/sops/raider.yaml` (one new key)

**Interfaces:**
- Consumes: `/tmp/niks3-cutover/r2-{access-key-id,secret-access-key}.txt` from Task 1. **Steps 1–4 need none of that** and may run before Task 1 — they are pure local key generation, and Tasks 6 and 8 are blocked on their output. Steps 5–8 need Task 1 complete.
- Produces: sops keys `niks3-api-token`, `niks3-sign-key`, `r2-access-key-id`, `r2-secret-access-key` on basestar and `niks3-api-token` on raider; the cache public key at `/tmp/niks3-cutover/cache-pubkey.txt`, which is `<CACHE_PUBKEY>` everywhere else in this plan.

- [ ] **Step 1: Generate the API token**

The module requires at least 36 characters. `openssl rand -base64 32` yields 44.

```bash
openssl rand -base64 32 | tr -d '\n' > /tmp/niks3-cutover/api-token.txt
chmod 600 /tmp/niks3-cutover/api-token.txt
wc -c < /tmp/niks3-cutover/api-token.txt
```

Expected: `44`.

- [ ] **Step 2: Generate the cache signing key**

```bash
nix key generate-secret --key-name cache.arsfeld.dev-1 > /tmp/niks3-cutover/sign-key.txt
chmod 600 /tmp/niks3-cutover/sign-key.txt
```

- [ ] **Step 3: Derive and record the public key**

```bash
nix key convert-secret-to-public < /tmp/niks3-cutover/sign-key.txt \
  > /tmp/niks3-cutover/cache-pubkey.txt
cat /tmp/niks3-cutover/cache-pubkey.txt
```

Expected: a single line of the form `cache.arsfeld.dev-1:<44 base64 chars>`.

Also copy it into the plan workspace, where later tasks read it without touching the
secret-bearing scratch directory:

```bash
cp /tmp/niks3-cutover/cache-pubkey.txt \
   .superpowers/sdd/2026-08-21-niks3-binary-cache/cache-pubkey.txt
```

The public key is not a secret — it ships in `modules/constellation/common.nix`.

- [ ] **Step 4: Pin `<CACHE_PUBKEY>` for the rest of the plan**

Every later occurrence of `<CACHE_PUBKEY>` in this plan is that exact line. Do not retype it from memory — read it back from `/tmp/niks3-cutover/cache-pubkey.txt` each time.

- [ ] **Step 5: Add the four keys to basestar's sops file**

sops edits are scripted, not interactive. Use `sops set` once per key, which round-trips the encrypted file in place:

Pass the value on **stdin**, never as an argument. `sops set` provides `--value-stdin`
precisely to avoid leaking secrets into process listings; the positional-value form would
put the API token and the R2 secret key into `ps` output and shell history. (Verified
available in sops 3.13.3, which is what the dev shell ships.)

```bash
set_secret() {  # $1 = sops file, $2 = key, $3 = plaintext file
  jq -Rs 'rtrimstr("\n")' < "$3" \
    | nix develop -c sops set --value-stdin "$1" "[\"$2\"]"
}

set_secret secrets/sops/basestar.yaml niks3-api-token       /tmp/niks3-cutover/api-token.txt
set_secret secrets/sops/basestar.yaml niks3-sign-key        /tmp/niks3-cutover/sign-key.txt
set_secret secrets/sops/basestar.yaml r2-access-key-id      /tmp/niks3-cutover/r2-access-key-id.txt
set_secret secrets/sops/basestar.yaml r2-secret-access-key  /tmp/niks3-cutover/r2-secret-access-key.txt
```

`jq -Rs` produces a correctly quoted JSON string, which is what `sops set` requires for its
value. `rtrimstr("\n")` drops the trailing newline. (`niks3-server` trims whitespace when
reading every one of these files, so a stray newline would be harmless — but keeping them
clean keeps a byte-for-byte comparison meaningful.)

- [ ] **Step 6: Add the shared API token to raider's sops file**

Same value. Two consumers on raider share it: the auto-upload daemon runs as root and can read it regardless, and `nix-fast-build --niks3-server` picks it up from `NIKS3_AUTH_TOKEN_FILE`.

```bash
set_secret secrets/sops/raider.yaml niks3-api-token /tmp/niks3-cutover/api-token.txt
```

(reusing the `set_secret` helper defined in Step 5 — same shell session, or redefine it)

- [ ] **Step 7: Verify both files decrypt and the token matches across them**

```bash
nix develop -c sops --decrypt --extract '["niks3-api-token"]' secrets/sops/basestar.yaml \
  | cmp - /tmp/niks3-cutover/api-token.txt && echo "basestar token OK"
nix develop -c sops --decrypt --extract '["niks3-api-token"]' secrets/sops/raider.yaml \
  | cmp - /tmp/niks3-cutover/api-token.txt && echo "raider token OK"
nix develop -c sops --decrypt --extract '["niks3-sign-key"]' secrets/sops/basestar.yaml \
  | nix key convert-secret-to-public | cmp - /tmp/niks3-cutover/cache-pubkey.txt \
  && echo "sign key OK"
```

Expected: all three `OK` lines, no `cmp` differences.

- [ ] **Step 8: Prove nothing pre-existing was clobbered — without decrypting it**

`sops set` rewrites the whole file, so it is worth proving the untouched keys survived.
Prove it by **key name and ciphertext stability**, never by decrypting a value:

```bash
for f in basestar raider; do
  echo "-- $f --"
  grep -oE '^[a-z0-9-]+:' "secrets/sops/$f.yaml" | tr -d ':' | tr '\n' ' '; echo
done
git diff HEAD -- secrets/sops/ | grep -E '^-' | grep -vE '^--- |lastmodified|mac:' \
  && echo "WARNING: a pre-existing line was removed or rewritten" \
  || echo "no pre-existing ciphertext lines removed"
```

Expected: basestar lists its 19 prior key names plus the 4 new ones; raider lists 3 plus 1;
and the only removed lines are `lastmodified` and `mac`, which sops rewrites by design.

**Never decrypt an unrelated secret to spot-check it.** A `sops --decrypt --extract` of
some other key prints live production plaintext into your report, your terminal scrollback
and the session transcript. If a value-level check is truly needed, compare hashes:
`sops --decrypt --extract '["k"]' f.yaml | sha256sum` before and after, and record only the
digest.

- [ ] **Step 9: Commit**

```bash
git add secrets/sops/basestar.yaml secrets/sops/raider.yaml
git commit -m "feat(secrets): add niks3 api token, sign key and R2 credentials"
```

---

### Task 3: Add the niks3 flake input and put the CLI in the dev shell

**Files:**
- Modify: `flake.nix:32` (after the `apple-fonts` input)
- Modify: `flake-modules/dev.nix:45` (`attic-client` → niks3)

**Interfaces:**
- Consumes: nothing.
- Produces: `inputs.niks3.nixosModules.niks3` (Task 4), `inputs.niks3.nixosModules.niks3-auto-upload` (Task 5), `inputs.niks3.packages.<system>.niks3` — the CLI providing `push`, `gc` and `pins` (Tasks 7, 8, 12, 13).

- [ ] **Step 1: Add the input**

The NixOS modules are not in nixpkgs — only the package is. Taking both from the flake keeps the module and the server binary version-locked, since the module defaults `serverPackage` to its own `callPackage`.

In `flake.nix`, immediately after the `apple-fonts.url` line:

```nix
    niks3.url = "github:Mic92/niks3"; # S3-backed binary cache coordinator (nixosModules not in nixpkgs)
    niks3.inputs.nixpkgs.follows = "nixpkgs";
```

- [ ] **Step 2: Lock the input and confirm the module attributes exist**

`nix flake lock` adds any input missing from the lock file without touching the ones already there — do not run a bare `nix flake update`, which would bump every input and turn this into an unrelated fleet-wide change.

```bash
nix flake lock
jq -r '.nodes.niks3.locked | "\(.owner)/\(.repo) \(.rev)"' flake.lock
nix eval --impure --json --expr \
  'builtins.attrNames (builtins.getFlake (toString ./.)).inputs.niks3.nixosModules'
```

Expected: `Mic92/niks3` with a 40-character revision, and an attribute list containing `niks3`, `niks3-auto-upload` and `default`.

- [ ] **Step 3: Swap the cache client in the dev shell**

`nix-fast-build`'s niks3 worker resolves the binary with `command -v niks3` and otherwise falls back to an unpinned `nix shell github:Mic92/niks3 -c niks3`. Putting the flake's own `niks3` on `PATH` is what keeps the CLI locked to the same revision as the server.

In `flake-modules/dev.nix`, replace line 45:

```nix
          attic-client
```

with:

```nix
          # nix-fast-build's --niks3-server worker resolves `niks3` from PATH
          # and otherwise falls back to an unpinned `nix shell
          # github:Mic92/niks3`. Take it from the input so the CLI, the module
          # and the server binary all move together.
          inputs.niks3.packages.${system}.niks3
```

- [ ] **Step 4: Format, then verify the CLI is present and speaks the expected flags**

```bash
just fmt
nix develop -c niks3 --help
nix develop -c niks3 push --help
```

Expected: `niks3 --help` lists `push`, `gc`, `pins`. `niks3 push --help` lists `--server-url`, `--auth-token-path` and `--auth-token-script`.

**Do not gate on `--pin` appearing in that help text — it does not, and that is an upstream
bug rather than a missing feature.** `cmd/niks3/main.go` registers the flag
(`pinName := pushCmd.String("pin", ...)`) and enforces `--pin requires exactly one store
path`, but the hand-written `printPushHelp()` never prints it. Gate on the parser instead,
which is what Task 8 actually depends on:

```bash
nix develop -c niks3 push --pin probe --server-url http://127.0.0.1:1 /nix/store 2>&1 | head -3
```

Expected: it gets **past flag parsing** — a connection error to `127.0.0.1:1`, or a store-path
validation complaint. **If it prints `flag provided but not defined: -pin`, stop**: the input
resolved to a CLI older than the pins feature and Task 8's push cannot work.

- [ ] **Step 5: Commit**

```bash
git add flake.nix flake.lock flake-modules/dev.nix
git commit -m "feat(modules): add niks3 flake input and dev-shell CLI"
```

---

### Task 4: The niks3 server on basestar

**Files:**
- Create: `hosts/basestar/services/niks3.nix`
- Modify: `hosts/basestar/services/default.nix` (add `./niks3.nix` to `imports`)
- Test: `nix eval '.#nixosConfigurations.basestar.config.system.build.toplevel.drvPath'`

**Interfaces:**
- Consumes: `inputs.niks3.nixosModules.niks3` (Task 3); sops keys `niks3-api-token`, `niks3-sign-key`, `r2-access-key-id`, `r2-secret-access-key` (Task 2).
- Produces: `services.niks3` on basestar listening on `127.0.0.1:5751`; a Caddy vhost `niks3.arsfeld.dev`; systemd units `niks3.socket`, `niks3.service`, `niks3-gc.service`, `niks3-gc.timer`; a PostgreSQL database and role both named `niks3`.

- [ ] **Step 1: Write the service file**

This follows the `siyuan.nix` shape — a plain `services.caddy.virtualHosts` entry with `useACMEHost = "arsfeld.dev"` — not `media.services`, which is the galactica gateway/container contract and would add tsnsrv, Authelia and a config-dir mount that none of this wants.

Create `hosts/basestar/services/niks3.nix`:

```nix
# niks3 — the write half of the binary cache.
#
# niks3 is a coordinator, not a cache. Clients ask it for presigned R2 URLs,
# compress and PUT NARs straight to R2, then commit the closure; the server
# only records references in Postgres so GC can reclaim them later, and never
# handles NAR bytes. Reads never reach basestar at all — nix pulls from
# https://cache.arsfeld.dev, which is the R2 bucket behind a custom domain.
#
# That split is the whole point of replacing attic. atticd terminated uploads,
# ran zstd in-process and reassembled NARs on read, all through one replica on
# a 7.9 GiB k3s node it shared with a control plane; when it died, reads died
# with it and three tier-1 hosts stopped being deployable under `max-jobs = 0`.
# Here a server outage costs writes only.
{
  config,
  inputs,
  ...
}: {
  imports = [inputs.niks3.nixosModules.niks3];

  services.niks3 = {
    enable = true;
    httpAddr = "127.0.0.1:5751";
    # Caddy owns 80/443 on this host. The upstream module's nginx vhost would
    # fight it for the ports and for the arsfeld.dev certificate.
    nginx.enable = false;

    s3 = {
      endpoint = "67a60cd5057ea97341c77d16f7cd3100.r2.cloudflarestorage.com";
      bucket = "nix-cache";
      # Required for R2. Left empty, the client infers the region from the
      # endpoint and defaults to us-east-1, and every request then fails
      # signature verification.
      region = "auto";
      accessKeyFile = config.sops.secrets.r2-access-key-id.path;
      secretKeyFile = config.sops.secrets.r2-secret-access-key.path;
    };

    apiTokenFile = config.sops.secrets.niks3-api-token.path;
    signKeyFiles = [config.sops.secrets.niks3-sign-key.path];
    cacheUrl = "https://cache.arsfeld.dev";
    serverUrl = "https://niks3.arsfeld.dev";

    # CI authenticates with a short-lived GitHub OIDC token instead of a
    # long-lived secret in the repo. `audience` must match the audience the
    # workflow requests, and boundSubject matches GitHub's `sub` claim, which
    # for a push to master is `repo:arsfeld/nixos:ref:refs/heads/master`.
    oidc.providers.github = {
      issuer = "https://token.actions.githubusercontent.com";
      audience = "https://niks3.arsfeld.dev";
      boundClaims.repository_owner = ["arsfeld"];
      boundSubject = ["repo:arsfeld/nixos:*"];
    };

    # 30 days, not attic's 6 months, because CI pins the tier-1 closures. The
    # server's delete query is explicit about the exemption:
    #
    #   DELETE FROM closures
    #   WHERE closures.updated_at < $1
    #     AND closures.key NOT IN (SELECT narinfo_key FROM pins);
    #
    # Object GC then walks reachability from the surviving closures, so
    # everything beneath a pinned toplevel lives too. That decouples two
    # retention needs a single olderThan cannot serve: the closure
    # weekly-deploy needs can never age out from under it, while everything
    # else — including every derivation raider auto-uploads — expires in a
    # month. Shorten this before disabling auto-upload if the bucket grows.
    gc = {
      enable = true;
      olderThan = "720h";
    };

    # maxNarSize is deliberately left unset. Multipart upload handles large
    # closures; a cap makes clients silently skip store paths, which becomes a
    # cache miss on a host deploying under `max-jobs = 0`, where a miss is a
    # hard failure rather than a local rebuild.
  };

  # database.createLocally defaults true and contributes `local all niks3 peer`
  # to services.postgresql.authentication at normal priority. planka's rules
  # and nixpkgs' own defaults are both lib.mkAfter, and the option is
  # types.lines, so the three definitions concatenate with this line first
  # rather than colliding. Nothing here disturbs planka's existing database.
  sops.secrets = {
    niks3-api-token = {
      owner = "niks3";
      group = "niks3";
      mode = "0400";
    };
    niks3-sign-key = {
      owner = "niks3";
      group = "niks3";
      mode = "0400";
    };
    r2-access-key-id = {
      owner = "niks3";
      group = "niks3";
      mode = "0400";
    };
    r2-secret-access-key = {
      owner = "niks3";
      group = "niks3";
      mode = "0400";
    };
  };

  # DNS-only (grey-cloud) A record to this host — see CLAUDE.md. Only CI and
  # `just deploy` ever talk to this hostname, and no NAR traverses it, so the
  # usual reason to proxy (Cloudflare's 100 MB body limit) does not apply.
  services.caddy.virtualHosts."niks3.arsfeld.dev" = {
    useACMEHost = "arsfeld.dev";
    extraConfig = ''
      encode zstd gzip

      reverse_proxy 127.0.0.1:5751 {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
      }
    '';
  };
}
```

- [ ] **Step 2: Wire it into the host**

In `hosts/basestar/services/default.nix`, add `./niks3.nix` to the `imports` list (alphabetically it sits between `./gatus.nix` and `./planka.nix`; the list is not strictly sorted, so appending after `./gatus.nix` is fine):

```nix
    ./gatus.nix
    ./niks3.nix
    ./planka.nix
```

- [ ] **Step 3: Format and evaluate**

Evaluating `drvPath` forces the whole module system including `config.assertions`, which is what catches a missing `accessKeyFile` or a bad option name. It does not build anything, so it does not need the aarch64 remote builder.

```bash
just fmt
nix eval '.#nixosConfigurations.basestar.config.system.build.toplevel.drvPath'
```

Expected: a single `/nix/store/…-nixos-system-basestar-….drv` path, no `error:`.

- [ ] **Step 4: Confirm the units and the postgres wiring actually landed**

```bash
nix eval --json '.#nixosConfigurations.basestar.config.systemd.services.niks3.serviceConfig.Type'
nix eval --json '.#nixosConfigurations.basestar.config.services.postgresql.ensureDatabases'
nix eval --raw '.#nixosConfigurations.basestar.config.services.postgresql.authentication'
```

Expected: `"notify"`; a list containing both `"planka"` and `"niks3"`; and a `pg_hba` body whose first non-comment line is `local all niks3 peer`, with planka's two `host planka planka …` lines and nixpkgs' four defaults still present below it.

- [ ] **Step 5: Commit**

```bash
git add hosts/basestar/services/niks3.nix hosts/basestar/services/default.nix
git commit -m "feat(basestar): add niks3 binary cache server"
```

---

### Task 5: Auto-upload on raider

**Files:**
- Modify: `hosts/raider/configuration.nix` — `imports` (line 9), sops secrets block (after line 37), the `constellation` block area for the new service, and `environment.sessionVariables` (line 419)
- Test: `nix eval '.#nixosConfigurations.raider.config.system.build.toplevel.drvPath'`

**Interfaces:**
- Consumes: `inputs.niks3.nixosModules.niks3-auto-upload` (Task 3); sops key `niks3-api-token` on raider (Task 2).
- Produces: `nix.settings.post-build-hook` on raider; units `niks3-auto-upload.socket` / `niks3-auto-upload.service`; the environment variable `NIKS3_AUTH_TOKEN_FILE=/run/secrets/niks3-api-token`, which Task 7's `just deploy` and Task 13's bridging deploy both rely on.

- [ ] **Step 1: Import the module**

In `hosts/raider/configuration.nix`, add to the `imports` list at line 9:

```nix
  imports = [
    ./hardware-configuration.nix
    ./disko-config.nix
    ./fan-control.nix
    ./fontconfig.nix
    ./harmonia.nix
    ./samba.nix
    inputs.niks3.nixosModules.niks3-auto-upload
  ];
```

`inputs` is already in this file's argument set (line 4), and `mkLinuxSystem` passes it through `specialArgs`.

- [ ] **Step 2: Declare the secret**

Immediately after the existing `sops.secrets."ntfy-publisher-env"` block (which ends at line 37), add:

```nix
  # Full-write cache credential on a workstation, which is worth naming
  # explicitly. niks3 supports exactly one API token alongside OIDC, so there
  # is no lower-privilege token to hand raider short of mTLS. It is not a
  # regression: raider already held an attic write token in
  # ~/.config/attic/config.toml.
  #
  # owner + mode let the interactive user read it, not just root. The
  # auto-upload daemon runs as root and could read it either way; the reason
  # for the user-readable mode is `nix-fast-build --niks3-server`, whose
  # upload worker shells out to `niks3 push` as the invoking user and resolves
  # its token from $NIKS3_AUTH_TOKEN_FILE. That avoids a second copy of the
  # token in ~/.config/niks3/auth-token.
  sops.secrets."niks3-api-token" = {
    owner = "arosenfeld";
    mode = "0400";
  };
```

- [ ] **Step 3: Enable the auto-upload daemon**

Add immediately after the `sops.secrets."niks3-api-token"` block:

```nix
  # Every derivation raider builds is uploaded as it finishes — not just what
  # CI builds or what `just deploy` pushes.
  #
  # The post-build hook itself does almost nothing: it writes the store path
  # to a unix socket and exits. That matters, because a post-build hook runs
  # inside every build, and one that uploaded synchronously would serialise
  # every build behind network I/O. The socket-activated daemon on the other
  # end batches 50 paths, uploads with 30-way concurrency, and exits after 60s
  # idle; behind it is a WAL-mode SQLite queue, so paths survive a crash or a
  # reboot mid-upload instead of being silently lost.
  #
  # raider only. blackbird is a laptop that is frequently tethered or offline,
  # and pushing every local build over a metered link is the wrong default;
  # galactica and basestar are deploy targets that rarely build anything not
  # already coming from CI.
  #
  # Note that post-build-hook is a global nix setting, not a list. Nothing
  # else in this repo sets one today, but a future module that wants one will
  # collide with this rather than compose with it.
  services.niks3-auto-upload = {
    enable = true;
    serverUrl = "https://niks3.arsfeld.dev";
    authTokenFile = config.sops.secrets."niks3-api-token".path;
  };
```

- [ ] **Step 4: Export the token path into the login session**

`nix-fast-build --niks3-server` copies the ambient environment into its `niks3 push` subprocess, and niks3 resolves `NIKS3_AUTH_TOKEN_FILE` ahead of the XDG default. Change `environment.sessionVariables` (line 419) from:

```nix
  environment.sessionVariables = {
    GAMES_DIR = "/mnt/games";
  };
```

to:

```nix
  environment.sessionVariables = {
    GAMES_DIR = "/mnt/games";
    # `just deploy` phase 1 pushes through nix-fast-build --niks3-server,
    # whose upload worker runs `niks3 push` as this user. Pointing it at the
    # sops secret keeps a single copy of the token on disk.
    NIKS3_AUTH_TOKEN_FILE = config.sops.secrets."niks3-api-token".path;
  };
```

- [ ] **Step 5: Format and evaluate**

```bash
just fmt
nix eval '.#nixosConfigurations.raider.config.system.build.toplevel.drvPath'
```

Expected: a `/nix/store/…-nixos-system-raider-….drv` path, no `error:`.

- [ ] **Step 6: Confirm the hook and socket landed as expected**

```bash
nix eval --raw '.#nixosConfigurations.raider.config.nix.settings.post-build-hook'
nix eval --json '.#nixosConfigurations.raider.config.systemd.sockets.niks3-auto-upload.socketConfig'
```

Expected: a store path ending in `niks3-post-build-hook`; and a socket config with `ListenStream = "/run/niks3/upload-to-cache.sock"`, `SocketUser = "root"`, `SocketGroup = "nixbld"`, `SocketMode = "0660"` — the group and mode are what let the nix daemon's build users write to it.

- [ ] **Step 7: Commit**

```bash
git add hosts/raider/configuration.nix
git commit -m "feat(raider): auto-upload local builds to niks3"
```

---

### Task 6: Fleet-wide substituter and trusted key

**Files:**
- Modify: `modules/constellation/common.nix:9` (header comment), `:51-55` (substituters and keys)
- Modify: `installer-iso.nix:17-20`
- Test: `nix eval` on two hosts

**Interfaces:**
- Consumes: `<CACHE_PUBKEY>` from Task 2.
- Produces: `https://cache.arsfeld.dev` in `nix.settings.substituters` and `<CACHE_PUBKEY>` in `trusted-public-keys` on every constellation host, and in the installer ISO's `nix.settings`.

- [ ] **Step 1: Add the substituter and key in `common.nix`**

Replace lines 50–55 of `modules/constellation/common.nix`:

```nix
        substituters = lib.mkAfter [
          "https://attic.arsfeld.dev/system"
        ];
        trusted-public-keys = lib.mkAfter [
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
          "https://cache.arsfeld.dev"
          # attic is frozen — CI no longer pushes to it — but still serves
          # every path it already holds, which keeps the cold-cache window
          # short while R2 fills. Dropped when attic is retired.
          "https://attic.arsfeld.dev/system"
        ];
        trusted-public-keys = lib.mkAfter [
          "<CACHE_PUBKEY>"
          "system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc="
        ];
```

- [ ] **Step 2: Update the module's header comment**

Line 9 of the same file reads:

```nix
# - Binary cache setup (nixos-community, numtide, attic, etc.)
```

Change to:

```nix
# - Binary cache setup (nixos-community, numtide, cache.arsfeld.dev, etc.)
```

- [ ] **Step 3: Do the same for the installer ISO**

`installer-iso.nix` is a standalone config that does not import the constellation modules, so it needs its own copy. Replace lines 16–20:

```nix
  # Enable flakes and Attic cache so nixos-install fetches pre-built packages
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    extra-substituters = ["https://attic.arsfeld.dev/system"];
    extra-trusted-public-keys = ["system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc="];
  };
```

with:

```nix
  # Enable flakes and the binary cache so nixos-install fetches pre-built
  # packages. This config does not import constellation.common, so it carries
  # its own copy of the substituter list.
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    extra-substituters = [
      "https://cache.arsfeld.dev"
      "https://attic.arsfeld.dev/system"
    ];
    extra-trusted-public-keys = [
      "<CACHE_PUBKEY>"
      "system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc="
    ];
  };
```

- [ ] **Step 4: Format and verify the key reached the hosts**

```bash
just fmt
nix eval --json '.#nixosConfigurations.galactica.config.nix.settings.substituters'
nix eval --json '.#nixosConfigurations.galactica.config.nix.settings.trusted-public-keys'
nix eval '.#nixosConfigurations.basestar.config.system.build.toplevel.drvPath'
```

Expected: `substituters` ends with `cache.arsfeld.dev` then `attic.arsfeld.dev/system` (both after `cache.nixos.org`, because of `mkAfter`); `trusted-public-keys` contains `<CACHE_PUBKEY>` verbatim; and basestar still evaluates.

- [ ] **Step 5: Commit**

```bash
git add modules/constellation/common.nix installer-iso.nix
git commit -m "feat(modules): add cache.arsfeld.dev substituter alongside attic"
```

---

### Task 7: Switch the deploy driver to niks3

**Files:**
- Modify: `justfile:27-30` (the deployment header comment), `:62-98` (`_apply` phase 1 and the push), `:218-228` (the `cache` recipe)
- Test: `just --evaluate`, `just --summary`

**Interfaces:**
- Consumes: the `niks3` CLI on `PATH` (Task 3); `NIKS3_AUTH_TOKEN_FILE` (Task 5, or a temporary override in Task 13).
- Produces: `just deploy` / `boot` / `test` / `dry-run` pushing to niks3 in phase 1; `just cache <host>` pushing a single host.

- [ ] **Step 1: Update the deployment section header**

`justfile` lines 27–30 currently read:

```
# === Deployment ===
# Phase 1 builds every named host in parallel and pushes to attic; phase 2
# activates each host in parallel from the pre-built closure. Nothing activates
# unless everything builds.
```

Replace the second line's `attic` with `niks3`:

```
# === Deployment ===
# Phase 1 builds every named host in parallel and pushes to niks3; phase 2
# activates each host in parallel from the pre-built closure. Nothing activates
# unless everything builds.
```

- [ ] **Step 2: Add `--niks3-server` to the nix-fast-build invocation**

In `_apply`, the phase 1 comment block and call currently read:

```bash
    # Phase 1 — parallel eval (one nix-eval-jobs worker per attr) and parallel
    # build. Two flags are load-bearing:
    #   --systems must name both. The default is the local system only, and
    #     nix-fast-build silently drops attrs for any other system, which would
    #     skip basestar (aarch64) entirely.
    #   Do NOT add --skip-cached. It makes nix-eval-jobs skip already-cached
    #     attrs outright, leaving no local store path for --store-path below.
    nix-fast-build \
      --flake '.#deployTargets' \
      --select "t: { inherit (t) ${hosts}; }" \
      --systems "x86_64-linux aarch64-linux" \
      --out-link "$out/result"
```

Replace that whole block with:

```bash
    # Phase 1 — parallel eval (one nix-eval-jobs worker per attr), parallel
    # build, and an inline push to niks3. Three flags are load-bearing:
    #   --systems must name both. The default is the local system only, and
    #     nix-fast-build silently drops attrs for any other system, which would
    #     skip basestar (aarch64) entirely.
    #   Do NOT add --skip-cached. It makes nix-eval-jobs skip already-cached
    #     attrs outright, leaving no local store path for --store-path below.
    #   --niks3-server registers each built closure with niks3, which hands
    #     back presigned R2 URLs; the NARs go from here straight to R2 and the
    #     server never sees them. Auth comes from $NIKS3_AUTH_TOKEN_FILE (set
    #     in raider's session env from the sops secret) or
    #     ~/.config/niks3/auth-token, and the `niks3` binary is resolved from
    #     PATH — the dev shell provides it, otherwise nix-fast-build silently
    #     falls back to an unpinned `nix shell github:Mic92/niks3`.
    #
    # Unlike the attic push this replaces, upload failures DO fold into
    # nix-fast-build's exit code, so a niks3 outage aborts before anything
    # activates. That is the intended trade: the closures are already built
    # locally, so re-running once the server is back costs nothing, whereas a
    # silently-skipped push leaves a closure that no target can substitute.
    # Phase 2's --use-substitutes is what keeps that from biting in the other
    # direction — a target that still cannot substitute receives the closure
    # over SSH instead of failing.
    nix-fast-build \
      --flake '.#deployTargets' \
      --select "t: { inherit (t) ${hosts}; }" \
      --systems "x86_64-linux aarch64-linux" \
      --niks3-server https://niks3.arsfeld.dev \
      --out-link "$out/result"
```

- [ ] **Step 3: Delete the separate attic push**

Remove this entire block (comment included) from `_apply`, between the `declare -A paths` loop and the `# Phase 2` comment:

```bash
    # Cache push is deliberately best-effort and deliberately NOT
    # nix-fast-build's own --attic-cache. That flag folds upload results into
    # its exit code, so a self-hosted attic being unreachable would abort the
    # deploy *after* paying the full build cost, with every closure fine. The
    # old recipes backgrounded `attic watch-store system &` and swallowed its
    # failure; this preserves that resilience.
    attic push system "${paths[@]}" \
      || echo "warning: attic push failed; deploying anyway" >&2
```

Leave the `declare -A paths` block above it and the phase 2 block below it untouched — `paths` is still what phase 2 feeds to `--store-path`.

- [ ] **Step 4: Update the `cache` recipe**

Replace the recipe at `justfile:217-228`:

```
# Build a host and push to Attic cache
cache HOST:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Building {{ HOST }}..."
    nix build '.#deployTargets.{{ HOST }}' --out-link result-{{ HOST }}

    echo "Pushing {{ HOST }} to Attic cache..."
    attic push system ./result-{{ HOST }}

    rm -f result-{{ HOST }}
    echo "✅ {{ HOST }} built and cached successfully"
```

with:

```
# Build a host and push it to the binary cache
cache HOST:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Building {{ HOST }}..."
    nix build '.#deployTargets.{{ HOST }}' --out-link result-{{ HOST }}

    echo "Pushing {{ HOST }} to niks3..."
    niks3 push --server-url https://niks3.arsfeld.dev ./result-{{ HOST }}

    rm -f result-{{ HOST }}
    echo "✅ {{ HOST }} built and cached successfully"
```

Note this recipe deliberately does **not** pass `--pin`. Pins are a CI concern: `--pin <host>` retargets a named pin, and a local ad-hoc build stealing a tier-1 host's pin would point it at a closure that was never CI-verified.

- [ ] **Step 5: Verify the justfile still parses and no attic references remain in it**

```bash
just --summary
grep -nE '\battic\b' justfile | grep -vE '^[0-9]+:[[:space:]]*#' || echo "no attic invocations in justfile"
```

Expected: `just --summary` lists every recipe including `deploy`, `cache`, `nr-deploy` and exits 0; the grep prints the "no attic invocations" line.

Gate on *invocations*, not on the word. A plain `grep -n attic justfile` still matches one line — the Step 2 comment "Unlike the attic push this replaces, upload failures DO fold into nix-fast-build's exit code" — and that sentence is the most useful thing in the block, because it names what changed about the failure semantics. Keep it. Task 15 Step 2's retire-attic sweep removes it once attic is actually gone.

- [ ] **Step 6: Commit**

Do **not** run `just deploy` yet — the server does not exist, and phase 1 now hard-fails when it cannot push. Task 10 bootstraps basestar with plain `nixos-rebuild` precisely to break that ordering cycle.

```bash
git add justfile
git commit -m "feat(modules): push deploy closures to niks3 instead of attic"
```

---

### Task 8: CI pushes to niks3 with an OIDC token

**Files:**
- Modify: `.github/workflows/build.yml:41-48` and `:109-116` (substituters), `:97-98` (permissions), `:122-161` (the push step)
- Modify: `.github/workflows/update.yml:44-45` (permissions on the reusable-workflow call)
- Modify: `.github/workflows/installer-iso.yml:24-27` (substituter)

**Interfaces:**
- Consumes: `<CACHE_PUBKEY>` (Task 2); the OIDC provider configured on the server (Task 4); the `niks3` CLI in the dev shell (Task 3).
- Produces: three pinned closures in the cache named `galactica`, `basestar`, `raider`, verified in Task 12.

- [ ] **Step 1: Add the substituter to both `install-nix-action` blocks in `build.yml`**

Both the `matrix` job (line 43) and the `build` job (line 111) carry the same `extra_nix_config`. In each, replace:

```yaml
            extra-substituters = https://attic.arsfeld.dev/system
            extra-trusted-public-keys = system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc=
```

with:

```yaml
            extra-substituters = https://cache.arsfeld.dev https://attic.arsfeld.dev/system
            extra-trusted-public-keys = <CACHE_PUBKEY> system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc=
```

nix.conf takes a space-separated list on one line; do not split these across lines.

- [ ] **Step 2: Grant the build job an OIDC token**

`build.yml` lines 97–98 read:

```yaml
    permissions:
      contents: read
```

Change to:

```yaml
    permissions:
      contents: read
      # niks3 authenticates CI with a short-lived GitHub OIDC token rather
      # than a long-lived secret. Without this, ACTIONS_ID_TOKEN_REQUEST_URL
      # and ACTIONS_ID_TOKEN_REQUEST_TOKEN are simply absent from the step
      # environment and the token script fails with an unset-variable error.
      id-token: write
```

- [ ] **Step 3: Grant it to the caller too**

`update.yml` calls `build.yml` as a reusable workflow, and a called workflow's `GITHUB_TOKEN` permissions can only be the same or more restrictive than the caller's. Without this the Sunday flake update builds fine and then fails to push every time. Change `update.yml` lines 44–45:

```yaml
    permissions:
      contents: read
```

to:

```yaml
    permissions:
      contents: read
      # A reusable workflow's token can only be as permissive as its caller's,
      # so build.yml's own `id-token: write` is not enough on its own.
      id-token: write
```

- [ ] **Step 4: Replace the push step in `build.yml`**

Replace the entire `Build and push to cache` step (lines 122–161) with:

```yaml
      - name: Build and push to cache
        shell: nix develop --command bash -e {0}
        run: |
          set -euo pipefail

          echo "Building ${{ matrix.host }}..."
          nix build '.#nixosConfigurations.${{ matrix.host }}.config.system.build.toplevel' \
            -o "result-${{ matrix.host }}"

          # niks3 authenticates with a GitHub OIDC token instead of a
          # long-lived secret. --auth-token-script is exec'd directly (shell
          # words are split, but no shell runs), so the file must be
          # executable and carry a shebang, and it must print exactly
          # {"token": "..."} on stdout — logs may go to stderr. Omitting
          # expires_at just means niks3 re-runs it per request, which is what
          # we want for a token this short-lived.
          #
          # The audience must match services.niks3.oidc.providers.github.audience
          # on basestar, and is URL-encoded because it is a query parameter.
          cat > /tmp/niks3-token.sh <<'TOKEN_SCRIPT'
          #!/usr/bin/env bash
          set -euo pipefail
          curl -fsSL \
            -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
            "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=https%3A%2F%2Fniks3.arsfeld.dev" \
            | jq -c '{token: .value}'
          TOKEN_SCRIPT
          chmod +x /tmp/niks3-token.sh

          echo "Pushing to niks3..."

          # Upstream ships Mic92/niks3-action@v1, which auto-configures the
          # substituter and a post-build hook. It is deliberately NOT used:
          # its uploads are asynchronous with a post-step drain, and whether a
          # failed upload fails the job is undocumented. This step therefore
          # keeps the exact shape the attic push had — an explicit command, a
          # four-attempt retry, a hard ::error:: exit — because that shape is
          # what the tier-1 gate below depends on.
          #
          # Retry transient push failures, but never swallow them. "push
          # failed => job failed => weekly-deploy's tier-1 gate skips this
          # commit" is exactly what stops galactica from deploying a closure
          # that is not substitutable, and it deploys under `max-jobs = 0`,
          # where a cache miss is a hard failure rather than a local rebuild.
          # `|| true` or continue-on-error here would turn a clean skip into a
          # broken deploy.
          #
          # --pin exempts this closure from the 30-day GC window; pushing again
          # under the same name retargets the pin and lets the previous closure
          # age out normally. Dropping it would leave weekly-deploy able to
          # fail on a closure that aged out from under it.
          pushed=0
          for attempt in 1 2 3 4; do
            if niks3 push \
                 --server-url https://niks3.arsfeld.dev \
                 --auth-token-script /tmp/niks3-token.sh \
                 --pin "${{ matrix.host }}" \
                 "./result-${{ matrix.host }}"; then
              pushed=1
              break
            fi
            echo "niks3 push attempt $attempt failed"
            # `[ ... ] && sleep` would be the loop body's last command, and a
            # false test there trips `set -e`. Use an explicit if.
            if [ "$attempt" -lt 4 ]; then
              sleep $((attempt * 15))
            fi
          done
          if [ "$pushed" -ne 1 ]; then
            echo "::error::niks3 push failed after 4 attempts for ${{ matrix.host }}" >&2
            exit 1
          fi

          echo "Done: ${{ matrix.host }} built and cached"
```

Note the `env:` block carrying `ATTIC_TOKEN` is gone — the step no longer reads it. Leave the `ATTIC_TOKEN` **repository secret** in place; deleting it is a Task 15 follow-up, because while it exists a one-commit revert restores a working push.

- [ ] **Step 5: Add the substituter to `installer-iso.yml`**

Lines 24–27 read:

```yaml
          extra_nix_config: |
            extra-substituters = https://attic.arsfeld.dev/system
            extra-trusted-public-keys = system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc=
```

Change to:

```yaml
          extra_nix_config: |
            extra-substituters = https://cache.arsfeld.dev https://attic.arsfeld.dev/system
            extra-trusted-public-keys = <CACHE_PUBKEY> system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc=
```

This workflow only reads; it never pushes, so it needs no `id-token` permission.

- [ ] **Step 6: Verify the workflow YAML parses and the token script is well-formed**

```bash
for f in .github/workflows/build.yml .github/workflows/update.yml .github/workflows/installer-iso.yml; do
  nix shell nixpkgs#yq-go -c yq -e '.jobs' "$f" >/dev/null && echo "$f OK"
done
nix shell nixpkgs#yq-go -c yq -r '.jobs.build.permissions' .github/workflows/build.yml
nix shell nixpkgs#yq-go -c yq -r '.jobs.build.permissions' .github/workflows/update.yml
```

Expected: three `OK` lines, and both `permissions` dumps show `id-token: write`.

Then dry-run the heredoc extraction to confirm the embedded script survived YAML block-scalar indentation stripping:

```bash
nix shell nixpkgs#yq-go -c yq -r \
  '.jobs.build.steps[] | select(.name == "Build and push to cache") | .run' \
  .github/workflows/build.yml | grep -n 'TOKEN_SCRIPT'
```

Expected: exactly two lines — the opening `cat > /tmp/niks3-token.sh <<'TOKEN_SCRIPT'` and the closing `TOKEN_SCRIPT` at column 0. If the terminator is indented, the heredoc will never close at runtime.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/build.yml .github/workflows/update.yml .github/workflows/installer-iso.yml
git commit -m "ci: push closures to niks3 with a GitHub OIDC token"
```

---

### Task 9: Documentation

CLAUDE.md is the load-bearing one. It currently documents the attic push as *deliberately best-effort* and describes a Traefik `readTimeout` constraint that ceases to exist with this change; both statements become actively misleading.

**Files:**
- Modify: `CLAUDE.md:28-40` (deploy phases), `:84` (weekly-deploy), `:91-95` (the attic/Traefik paragraph), `:265-268` (CI/CD)
- Modify: `README.md:55`, `:57`, `:60`, `:133`
- Modify: `docs/guides/getting-started.md:41`
- Modify: `.github/workflows/fix-ci.yml:99`
- Modify: `modules/constellation/weekly-deploy.nix:5`, `:191`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Rewrite CLAUDE.md's deploy-phase paragraph**

Replace the paragraph at `CLAUDE.md:31-40` (beginning "`just deploy` runs in two phases." and ending "…tier-1 precondition actually gates on.)") with:

```markdown
`just deploy` runs in two phases. Phase 1 is `nix-fast-build` over `.#deployTargets`:
parallel evaluation via nix-eval-jobs, parallel build, and an inline push to niks3 via
`--niks3-server`. Phase 2 activates each host in parallel with `nixos-rebuild
--store-path`, which skips evaluation and build entirely, and `--use-substitutes`, so each
target pulls its own closure from `cache.arsfeld.dev` instead of receiving NARs over
Tailscale.

`--niks3-server` folds upload results into nix-fast-build's exit code, so a niks3 outage
aborts the deploy before anything activates. That is the intended trade — the closures are
already built locally, so a re-run once the server is back costs nothing, whereas a
silently-skipped push leaves behind a closure no target can substitute. It also means
`just deploy` cannot be used to bootstrap niks3 itself; see the note in
`hosts/basestar/services/niks3.nix`. In the other direction, `--use-substitutes` degrades
rather than fails: a target that cannot substitute — an untrusted key, an empty cache —
receives the closure over SSH.
```

- [ ] **Step 2: Rewrite CLAUDE.md's attic/Traefik paragraph**

Replace `CLAUDE.md:91-95` (beginning "Attic (`attic.arsfeld.dev`) runs in k3s on `can-1`…") with:

```markdown
The binary cache is two endpoints, and only one of them is a server:

- **Read** — `https://cache.arsfeld.dev` is the R2 bucket `nix-cache` with a custom domain
  attached. Attaching the domain is what makes objects publicly readable; there is no
  separate toggle and the managed `r2.dev` domain stays disabled. No machine of ours is in
  this path, so nothing we run can make a substitution fail. **Never add an R2 lifecycle
  rule to this bucket** — niks3's GC deletes objects from its own Postgres reference table,
  and a rule deleting them behind its back leaves narinfos pointing at absent NARs, which
  fails only at deploy time.
- **Write** — `https://niks3.arsfeld.dev` is niks3 on basestar behind Caddy, reached by a
  **grey-cloud** (DNS-only) A record to `168.138.71.109`. Clients ask it for presigned R2
  URLs and PUT NARs straight to R2; the server only sees JSON. Grey-cloud is not optional:
  proxied records serve GitHub-hosted runners a managed challenge (HTTP 403), the same
  reason CI can never post to `ntfy.arsfeld.one`. The usual argument for proxying —
  Cloudflare's 100 MB body limit — does not apply, because no NAR traverses this hostname.

CI pushes each tier-1 closure with `niks3 push --pin <host>`. Pinned closures are exempt
from the 30-day GC window, and object GC walks reachability from surviving closures, so
everything beneath a pinned toplevel survives too. That is what makes the window safe: the
closure `weekly-deploy` needs under `max-jobs = 0` can never age out from under it, while
everything else — including every derivation raider auto-uploads via its post-build hook —
expires in a month. If the bucket grows past expectations, shorten `olderThan` rather than
disabling auto-upload.

One consequence worth knowing before you touch basestar: it is now in CI's push path.
Deploying or rebooting it during a `build.yml` run fails that run's push. It fails safe —
job red, tier-1 gate skips the commit — and `just deploy @tier1` is unaffected, because
phase 1 finishes every push before phase 2 activates anything, and niks3 is socket-activated
so connections queue across its own restart rather than being refused.

attic (`attic.arsfeld.dev`, k3s on can-1) is frozen but still running and still listed as a
substituter, so reverting one commit restores a fully populated cache. Retiring it — the
argocd app, the `attic-cache` bucket, the `ATTIC_TOKEN` secret — is a separate later change.
```

- [ ] **Step 3: Fix CLAUDE.md's two remaining attic mentions**

Line 84 currently reads:

```markdown
  has not built is absent from attic, and `max-jobs = 0` then fails rather than building.
```

Change `attic` to `the cache`:

```markdown
  has not built is absent from the cache, and `max-jobs = 0` then fails rather than building.
```

And in the CI/CD section near the end, the `build.yml` bullet reads:

```markdown
- **build.yml** - Builds basestar (aarch64), galactica (x86_64), raider (x86_64) closures and pushes to Attic cache
```

Change to:

```markdown
- **build.yml** - Builds basestar (aarch64), galactica (x86_64), raider (x86_64) closures and pushes them to niks3, pinned per host
```

Then confirm nothing was missed:

```bash
grep -n -i attic CLAUDE.md
```

Expected: only the two intentional mentions inside the paragraph written in Step 2.

- [ ] **Step 4: Update README.md**

Four lines:

- Line 55: `…(parallel eval, build, attic push, then parallel activation)…` → `…(parallel eval, build, niks3 push, then parallel activation)…`
- Line 57: `- **Binary Caching** - Attic server for faster builds` → `- **Binary Caching** - niks3 coordinator with a Cloudflare R2 read path (\`cache.arsfeld.dev\`)`
- Line 60: `- **CI/CD** - GitHub Actions builds all hosts, pushes to Attic cache, weekly flake updates` → `- **CI/CD** - GitHub Actions builds all hosts, pushes to niks3, weekly flake updates`
- Line 133: `- [Attic](https://github.com/zhaofengli/attic) - Binary cache` → `- [niks3](https://github.com/Mic92/niks3) - S3-backed binary cache with reference-tracking GC`

- [ ] **Step 5: Update the dev-shell tool list**

`docs/guides/getting-started.md:41` reads `- \`attic\`: Binary cache client`. Change to:

```markdown
- `niks3`: Binary cache client
```

Leave the stale `deploy-rs` and `agenix` entries above it alone — they are a separate problem and not in this change's scope.

- [ ] **Step 6: Update the fix-ci.yml transient-failure example**

`.github/workflows/fix-ci.yml:99` reads:

```
              - `attic push` failing with `HTTP 499 Client Closed Request` (the build itself succeeded).
```

Change to:

```
              - `niks3 push` failing with a 5xx, a connection error to `niks3.arsfeld.dev`, or an
                S3 upload error (the build itself succeeded).
```

- [ ] **Step 7: Update the two weekly-deploy comments**

`modules/constellation/weekly-deploy.nix:5`:

```nix
# a closure missing from attic is a loud error instead of a compile that OOMs
```

→

```nix
# a closure missing from the cache is a loud error instead of a compile that OOMs
```

`modules/constellation/weekly-deploy.nix:191`:

```nix
    # which CI ever built, so every host would fail on an attic 404 under
```

→

```nix
    # which CI ever built, so every host would fail on a cache miss under
```

These are comments only — `weekly-deploy` itself needs no behaviour change. It runs `nixos-rebuild switch --flake <repo>#<host>` under `max-jobs = 0` and substitutes from whatever the *currently active* generation's `/etc/nix/nix.conf` lists, which Task 13 is what updates.

- [ ] **Step 8: Verify no stale references remain anywhere that matters**

```bash
grep -rn -i attic --include=*.nix --include=*.yml --include=justfile --include=*.just \
  --include=CLAUDE.md --include=README.md docs/guides/ . 2>/dev/null \
  | grep -v '^./docs/plans/' | grep -v '^./docs/superpowers/' | grep -v '^./blog/'
```

Expected: only the deliberate mentions — the two substituter entries with their comments in `modules/constellation/common.nix` and `installer-iso.nix`, and the closing paragraph of CLAUDE.md's cache section. Historical plans under `docs/plans/`, the superpowers spec, and the blog post are records of what was true then; leave them.

- [ ] **Step 9: Format and commit**

```bash
just fmt
git add CLAUDE.md README.md docs/guides/getting-started.md \
        .github/workflows/fix-ci.yml modules/constellation/weekly-deploy.nix
git commit -m "docs(modules): describe the niks3 cache and its two endpoints"
```

---

### Task 10: Bootstrap basestar from the local tree

Everything is committed and nothing is pushed. This is the one step where ordering bites: `just deploy basestar` would run phase 1 with `--niks3-server https://niks3.arsfeld.dev`, which does not exist yet, and now that upload failures fold into the exit code the deploy would abort before activating the very server it is trying to create.

**Files:** none — no commit.

**Interfaces:**
- Consumes: the local commits from Tasks 2–9.
- Produces: a running `niks3.service` on basestar, an initialised `nix-cache` bucket containing `nix-cache-info` and the generated landing page.

- [ ] **Step 1: Confirm the working tree is clean and unpushed**

```bash
git status --porcelain
git log --oneline origin/master..HEAD
```

Expected: no output from the first (an untracked file would change `self` and therefore every closure's out-path); seven or eight commits from the second, none of them on the remote yet.

- [ ] **Step 2: Deploy basestar with plain nixos-rebuild**

Not `just deploy basestar`. This bypasses the push path entirely.

```bash
nixos-rebuild switch --flake .#basestar --target-host root@basestar.bat-boa.ts.net
```

The aarch64 build is dispatched to basestar itself via `nix.buildMachines` (it is the fleet's aarch64 remote builder), and most of the closure substitutes from attic, which is still listed and still populated. Only the niks3 server binary and the new toplevel actually build.

If this fails partway, `just nr-deploy basestar` is the repo's own equivalent recipe (it adds `--sudo`); either is fine.

- [ ] **Step 3: Verify the server is up and its watchdog is satisfied**

```bash
ssh root@basestar.bat-boa.ts.net systemctl status niks3.socket niks3.service --no-pager
```

Expected: `niks3.socket` active (listening), `niks3.service` `active (running)` with `Status: "Ready"` or equivalent, and **no** repeated `Watchdog timeout` restarts. The unit is `Type=notify` with a 30s watchdog gated on a Postgres ping, so a flapping unit here means the database connection is the problem, not the S3 config.

- [ ] **Step 4: If it is not running, read the logs before changing anything**

```bash
ssh root@basestar.bat-boa.ts.net journalctl -u niks3 -n 80 --no-pager
```

The three failures worth recognising:
- `signature verification failed` / `SignatureDoesNotMatch` → `s3.region` is not `"auto"`.
- `token must be at least 36 characters` → the API token secret is short or empty; re-check Task 2 Step 7.
- `role "niks3" does not exist` / `peer authentication failed` → postgres. Confirm the role and the rule both exist on the target:

```bash
ssh root@basestar.bat-boa.ts.net "sudo -u postgres psql -tAc '\\du niks3'"
ssh root@basestar.bat-boa.ts.net "cat \$(sudo -u postgres psql -tAc 'SHOW hba_file')"
```

- [ ] **Step 5: Verify the bucket was initialised**

```bash
curl -fsS https://cache.arsfeld.dev/nix-cache-info
```

Expected: a body containing `StoreDir: /nix/store` (plus `WantMassQuery` and `Priority` lines). niks3 writes this on startup, so its presence proves the R2 credential, the bucket name and the custom domain are all correct at once.

- [ ] **Step 6: Verify the write endpoint is reachable from outside Tailscale**

This is what proves the grey-cloud record resolves to Caddy and that no managed challenge intercepts it. Run it from a network that is not on the tailnet, or force it:

```bash
curl -fsS --resolve niks3.arsfeld.dev:443:168.138.71.109 https://niks3.arsfeld.dev/api/cache-config
```

Expected: a JSON body. A `403` with Cloudflare HTML means the DNS record is proxied — go back to Task 1 Step 6.

---

### Task 11: Push and get CI green

**Files:** none — no commit.

**Interfaces:**
- Consumes: the running server (Task 10).
- Produces: a populated cache and three pins, verified in Task 12.

- [ ] **Step 1: Push**

```bash
git push origin master
```

- [ ] **Step 2: Watch the build**

```bash
gh run watch "$(gh run list --workflow=build.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Expected: all nine matrix jobs green. The three that matter most are `galactica`, `basestar` and `raider`.

- [ ] **Step 3: Confirm the push step actually pushed**

```bash
gh run view "$(gh run list --workflow=build.yml --limit 1 --json databaseId --jq '.[0].databaseId')" \
  --log --job raider 2>/dev/null | grep -E "Pushing to niks3|Created pin|Done: raider"
```

Expected: `Pushing to niks3...`, a `Created pin` line naming `raider`, and `Done: raider built and cached`.

If instead you see `ACTIONS_ID_TOKEN_REQUEST_URL: unbound variable`, the `id-token: write` permission did not take — recheck Task 8 Steps 2 and 3. If you see a 401/403 from niks3, the `audience` or `boundSubject` on basestar does not match; compare against Task 4 Step 1.

---

### Task 12: The gating check — prove the cache is substitutable

This reproduces `weekly-deploy`'s constraint exactly. It is the check that decides whether the fleet can be bridged.

**Files:** none — no commit.

**Interfaces:**
- Consumes: a green CI run (Task 11); `<CACHE_PUBKEY>` (Task 2).
- Produces: confidence that Task 13 will not strand a host.

- [ ] **Step 1: Run the max-jobs-0 build for each tier-1 host**

`--max-jobs 0` makes local compilation impossible, so this passes only if every path is substitutable — exactly the condition `weekly-deploy` runs under. Run it on raider:

`--builders ''` is as load-bearing as `--max-jobs 0` here. `max-jobs = 0` only forbids *local* building; raider has basestar configured as an aarch64 remote builder, so without this flag a missing aarch64 path would quietly build on basestar and the check would pass on a cache that is actually incomplete.

```bash
for host in galactica basestar raider; do
  echo "=== $host ==="
  nix build --max-jobs 0 --no-link --builders '' \
    --option extra-substituters https://cache.arsfeld.dev \
    --option extra-trusted-public-keys "$(cat /tmp/niks3-cutover/cache-pubkey.txt)" \
    ".#nixosConfigurations.${host}.config.system.build.toplevel" \
    && echo "$host OK" || echo "$host FAILED"
done
```

Expected: three `OK` lines.

`--option extra-substituters` *appends* to the ambient list, so `cache.nixos.org` and the still-configured attic also participate — which is correct, because the real deploy has them too. This check proves the fleet is deployable, not that R2 alone holds every path.

- [ ] **Step 2: Pay particular attention to raider**

raider's closure is the one that depends entirely on CI having pushed successfully: vscode is unfree and never on `cache.nixos.org`, so nothing else can supply it. If `galactica` and `basestar` pass but `raider` fails, the push did not complete — do not proceed to Task 13.

- [ ] **Step 3: Verify the pins**

```bash
nix develop -c niks3 pins list --server-url https://niks3.arsfeld.dev
```

Expected: exactly three rows — `galactica`, `basestar`, `raider` — each with a store path matching the closure CI just built, and a recent `UPDATED AT`. Cross-check one:

```bash
nix eval --raw '.#nixosConfigurations.raider.config.system.build.toplevel'
```

Expected: the printed store path equals the `raider` pin's store path.

If `niks3 pins list` fails with an auth error, the shell predates Task 5's deployment and `NIKS3_AUTH_TOKEN_FILE` is not set yet — use the temporary override from Task 13 Step 1.

---

### Task 13: Bridge the fleet

This single command both populates the cache further and installs the `nix.conf` that trusts it. It is what resolves the cutover trap: `weekly-deploy` substitutes using the *currently active* generation's `/etc/nix/nix.conf`, which still lists only attic and still trusts only `system:mUX40QMM…`, so a naive push-and-wait would fail all three tier-1 hosts at once on key trust rather than on a failed upload. `nixos-rebuild --store-path --target-host --use-substitutes` sidesteps it by construction: when a target cannot substitute — exactly the untrusted-key case — it copies the closure over SSH instead of failing.

**Files:** none — no commit.

**Interfaces:**
- Consumes: a passing gating check (Task 12).
- Produces: all three tier-1 hosts running a generation that trusts `cache.arsfeld.dev`; auto-upload live on raider.

- [ ] **Step 1: Supply the push token for this one deploy**

raider does not have the sops secret yet — this deploy is what installs it — so `NIKS3_AUTH_TOKEN_FILE` from Task 5 does not exist on disk. Provide it for this invocation only:

```bash
umask 077
nix develop -c sops --decrypt --extract '["niks3-api-token"]' secrets/sops/raider.yaml \
  > /tmp/niks3-cutover/token-bootstrap.txt
```

- [ ] **Step 2: Deploy tier 1**

```bash
NIKS3_AUTH_TOKEN_FILE=/tmp/niks3-cutover/token-bootstrap.txt just deploy @tier1
```

`just` passes its environment through to the recipe's `bash`, and nix-fast-build copies it into the `niks3 push` subprocess.

Expected: phase 1 builds and pushes with no errors, then three parallel `[galactica] …`, `[basestar] …`, `[raider] …` activation streams, and exit 0.

- [ ] **Step 3: Remove the bootstrap token copy**

```bash
shred -u /tmp/niks3-cutover/token-bootstrap.txt
```

From here on the sops secret at `/run/secrets/niks3-api-token` is the only copy, and `NIKS3_AUTH_TOKEN_FILE` points at it. **That variable comes from `environment.sessionVariables`, so it is only set in a new login session** — an already-open terminal will not have it. Log out and back in, or export it by hand, before the next `just deploy`.

- [ ] **Step 4: Confirm each host now trusts the new key**

```bash
for host in galactica basestar raider; do
  echo "=== $host ==="
  ssh "root@${host}.bat-boa.ts.net" grep -c 'cache.arsfeld.dev' /etc/nix/nix.conf
done
```

Expected: a non-zero count for each (the substituter line and the trusted-key line both match).

- [ ] **Step 5: Verify auto-upload on raider**

```bash
systemctl status niks3-auto-upload.socket --no-pager
```

Expected: active (listening) on `/run/niks3/upload-to-cache.sock`. The `.service` will be inactive — it is socket-activated and exits after 60s idle; that is correct, not a failure.

- [ ] **Step 6: Force a build and watch it drain**

```bash
nix build nixpkgs#hello --rebuild --no-link -L
journalctl -u niks3-auto-upload -n 40 --no-pager
```

Expected: the journal shows the daemon starting, receiving the path, uploading a batch, and later exiting on its idle timeout. If nothing appears, check that the hook is installed: `grep post-build-hook /etc/nix/nix.conf`.

- [ ] **Step 7: Confirm the path is fetchable from the cache**

```bash
hash=$(nix path-info nixpkgs#hello --json | jq -r 'keys[0]' | sed 's|/nix/store/||; s|-.*||')
curl -fsS "https://cache.arsfeld.dev/${hash}.narinfo" | head -5
```

Expected: a narinfo body with `StorePath:`, `URL: nar/…`, `Compression: zstd` and a `Sig: cache.arsfeld.dev-1:…` line. The signature name proves the signing key is the one from Task 2.

---

### Task 14: Verify GC, then hand off

**Files:** none — no commit.

**Interfaces:**
- Consumes: a bridged fleet (Task 13).
- Produces: a verified GC run and a clean scratch directory.

- [ ] **Step 1: Record the pin list and object count before GC**

```bash
nix develop -c niks3 pins list --server-url https://niks3.arsfeld.dev --json \
  > /tmp/niks3-cutover/pins-before.json
export AWS_ACCESS_KEY_ID="$(cat /tmp/niks3-cutover/r2-access-key-id.txt)"
export AWS_SECRET_ACCESS_KEY="$(cat /tmp/niks3-cutover/r2-secret-access-key.txt)"
export AWS_DEFAULT_REGION=auto
export AWS_ENDPOINT_URL="https://67a60cd5057ea97341c77d16f7cd3100.r2.cloudflarestorage.com"
nix shell nixpkgs#awscli2 -c aws s3 ls s3://nix-cache/nar/ --recursive --summarize \
  | tail -3 | tee /tmp/niks3-cutover/objects-before.txt
```

- [ ] **Step 2: Run GC by hand**

```bash
ssh root@basestar.bat-boa.ts.net systemctl start niks3-gc
ssh root@basestar.bat-boa.ts.net journalctl -u niks3-gc -n 40 --no-pager
```

Expected: `Garbage collection completed successfully` with a stats line reporting `old-closures-deleted`, `objects-marked-for-deletion` and `objects-deleted-after-grace-period`. On a cache this young, `old-closures-deleted` should be `0` — nothing is 30 days old yet.

- [ ] **Step 3: Confirm GC did not touch a live closure**

```bash
nix develop -c niks3 pins list --server-url https://niks3.arsfeld.dev --json \
  | diff - /tmp/niks3-cutover/pins-before.json && echo "pins unchanged"
nix shell nixpkgs#awscli2 -c aws s3 ls s3://nix-cache/nar/ --recursive --summarize | tail -3
```

Expected: `pins unchanged`, and an object count that fell only where the GC log said it would (most likely: not at all).

Then re-run the gating check to be certain nothing was pulled out from underneath the fleet:

```bash
nix build --max-jobs 0 --no-link --builders '' \
  --option extra-substituters https://cache.arsfeld.dev \
  --option extra-trusted-public-keys "$(cat /tmp/niks3-cutover/cache-pubkey.txt)" \
  '.#nixosConfigurations.raider.config.system.build.toplevel' && echo "still substitutable"
```

- [ ] **Step 4: Destroy the scratch directory**

It holds the API token, the signing secret key and the R2 credentials in plaintext.

```bash
find /tmp/niks3-cutover -type f -exec shred -u {} +
rmdir /tmp/niks3-cutover
```

`<CACHE_PUBKEY>` is public and is already committed in `modules/constellation/common.nix`, so nothing is lost.

- [ ] **Step 5: Report status**

Summarise for the user: which R2 credential was used (reused vs newly minted), the three pins, the GC result, and the two outstanding follow-ups from Task 15.

---

### Task 15: Follow-ups (do not perform now)

Record these; they are deliberately out of this change's scope. Nothing here is actionable until one clean `weekly-deploy` run has completed on a Sunday at 06:00 UTC — that is the last unverified path, because it exercises the `max-jobs = 0` substitution against the *deployed* nix.conf rather than a `--option` override.

- [ ] **Step 1: Watch the first weekly-deploy**

The Sunday after the cutover, check the ntfy summary and:

```bash
ssh root@galactica.bat-boa.ts.net journalctl -u weekly-deploy -n 100 --no-pager
```

Expected: three healthy hosts, no cache misses. A failure here means a host's active generation does not trust `cache.arsfeld.dev` — which Task 13 Step 4 should have already ruled out.

- [ ] **Step 2: Record the retire-attic work**

After one clean run, a separate change should: delete the argocd attic app and the `attic-cache` bucket (plus the stale empty `attic` and `attic-data` buckets from 2024 — both confirmed present 2026-08-21); drop `https://attic.arsfeld.dev/system` and `system:mUX40QMM…` from `modules/constellation/common.nix`, `installer-iso.nix`, `.github/workflows/build.yml` and `.github/workflows/installer-iso.yml`; delete the `ATTIC_TOKEN` GitHub secret; remove the final attic paragraph from CLAUDE.md; and drop the now-stale contrast clause "Unlike the attic push this replaces" from the phase-1 comment in `justfile`'s `_apply`.

- [ ] **Step 3: Confirm the credential rotation is already done**

Under Deviation 8 the R2 token is minted fresh and scoped to `nix-cache` in Task 1, so the spec's shared-credential risk never materialises and this follow-up is satisfied on day one. Confirm the token in `secrets/sops/basestar.yaml` is the scoped one and record that no rotation is outstanding. Only if Task 1 fell back to reusing attic's account-wide credential does this become real work: mint a bucket-scoped token and update `r2-access-key-id` / `r2-secret-access-key`.

- [ ] **Step 4: Record the storage watch**

Bucket growth is now driven by local work, not just CI: every derivation raider builds lands in R2. Check the R2 storage metric a month after cutover. If it has grown past expectations, shorten `services.niks3.gc.olderThan` on basestar rather than disabling auto-upload — the pins mean a shorter window does not endanger deploys.
