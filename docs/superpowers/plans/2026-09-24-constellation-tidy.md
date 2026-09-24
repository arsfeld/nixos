# Constellation Tidy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move host-only `constellation.*` modules out of the haumea-loaded `modules/` tree into `hosts/<host>/`, delete two dead ones, and drop `enable` flags that only ever switch a module on — with zero change to any built system.

**Architecture:** Four commits: delete, pure `git mv` + imports, unwrap `mkIf cfg.enable`, docs. Every commit is proven behaviour-neutral by comparing each host's toplevel `drvPath` (and each flake check's) against a baseline taken before any edit, using `nix-diff` where they differ.

**Tech Stack:** Nix flakes, flake-parts, haumea, alejandra, nix-diff.

**Spec:** `docs/superpowers/specs/2026-09-24-constellation-tidy-design.md`

## Global Constraints

- Repo root: `/home/arosenfeld/Code/nixos`. Commit straight to `master`; no branches, no worktrees.
- Start from a clean working tree. If `git status --short` shows anything before Task 0, stop and ask — do not stage someone else's edits.
- Always commit after a precise `git add` or with an explicit pathspec; never `git add -A` / `git commit -a`.
- Conventional commits, no mention of Claude, no attribution lines.
- Flakes see only tracked files: `git mv` keeps files tracked; any newly created file needs `git add -N <path>` before evaluating.
- Run `just fmt` (alejandra) before each commit.
- No deploy. Nothing may change on any host except the flake revision it carries.

## Verification harness

Used by every task. `S` is a scratch directory outside the repo:

```bash
S=/tmp/claude-1000/-home-arosenfeld-Code-nixos/38306b57-7c5d-49ec-bbcb-45ba536cb7fc/scratchpad/tidy
```

`$S/snapshot.sh <dir>` — records the `drvPath` of every host toplevel and every flake check except `pre-commit-check` (which hashes the source tree, so it always changes) and the three checks that already fail on master:

```bash
#!/usr/bin/env bash
set -euo pipefail
out=$1
mkdir -p "$out"
cd /home/arosenfeld/Code/nixos
for h in basestar blackbird cylon-link galactica octopi pegasus r2s raider raspi3 router; do
  nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" >"$out/host-$h" &
done
wait
# router-test, router-test-production and cylon-link-config already fail to
# evaluate on master (pre-existing, unrelated to this change), so they are left out.
for c in blackbird-audio-control-test cylon-link-boot harmonia-cache-test immich-pixel-sync-test; do
  nix eval --raw ".#checks.x86_64-linux.$c.drvPath" >"$out/check-$c"
done
ls "$out" | wc -l   # expect 14
```

`$S/compare.sh <before> <after>` — prints `same`/`DIFF` per entry, and a `nix-diff` for each difference:

```bash
#!/usr/bin/env bash
set -uo pipefail
rc=0
for f in "$1"/*; do
  n=$(basename "$f")
  a=$(<"$f")
  b=$(<"$2/$n")
  if [ "$a" = "$b" ]; then
    echo "same  $n"
  else
    echo "DIFF  $n"
    nix run nixpkgs#nix-diff -- --color never "$a" "$b" | sed 's/^/    /'
    rc=1
  fi
done
exit $rc
```

**Acceptance rule (applies to every "compare" step):** each entry is either `same`, or a `DIFF` whose `nix-diff` output names *only* (a) the flake's own source store path (a `…-source` input) and (b) strings derived from the flake revision — `configurationRevision`, `/etc/os-release`'s version/build ID, the `nixos-version` JSON. A difference in any package, unit file, `/etc` entry, or option-derived file is a failure: stop, find which edit caused it, and fix it before committing.

---

### Task 0: Baseline

**Files:** none in the repo; creates `$S/snapshot.sh`, `$S/compare.sh`, `$S/base/`.

- [ ] **Step 1:** Create `$S`, write the two scripts above into it, `chmod +x` both.
- [ ] **Step 2:** Confirm the tree is clean: `git status --short` prints nothing.
- [ ] **Step 3:** `$S/snapshot.sh $S/base` — expect `14`.
- [ ] **Step 4:** Sanity-check the harness against itself: `$S/compare.sh $S/base $S/base` — expect 14 × `same`, exit 0.

---

### Task 1: Delete dead modules

**Files:**
- Delete: `modules/constellation/metrics-client.nix`
- Delete: `modules/constellation/sites/rosenfeld-blog.nix`

- [ ] **Step 1: Re-confirm nothing references them.**

```bash
grep -rnE "metrics-client|metricsClient|rosenfeld-blog" hosts modules flake-modules tests --include=*.nix \
  | grep -vE "^modules/constellation/(metrics-client|sites/rosenfeld-blog)\.nix"
```
Expected: no output.

- [ ] **Step 2:** `git rm modules/constellation/metrics-client.nix modules/constellation/sites/rosenfeld-blog.nix`
- [ ] **Step 3:** `$S/snapshot.sh $S/t1 && $S/compare.sh $S/base $S/t1` — apply the acceptance rule.
- [ ] **Step 4: Commit.**

```bash
git commit -m "refactor(modules): delete unused metrics-client and rosenfeld-blog" -- \
  modules/constellation/metrics-client.nix modules/constellation/sites/rosenfeld-blog.nix
```

---

### Task 2: Move host-only modules into their hosts (pure rename + wiring)

No content change to any moved file except the relative-path fix in `checks.nix` and comments that cite old paths. Enable flags stay untouched in this task.

**Files:**
- Move (git mv), galactica:
  - `modules/constellation/weekly-deploy.nix` → `hosts/galactica/weekly-deploy.nix`
  - `modules/constellation/rustic.nix` → `hosts/galactica/backup/rustic.nix`
  - `modules/constellation/opencloud.nix` → `hosts/galactica/services/opencloud.nix`
  - `modules/constellation/home-assistant.nix` → `hosts/galactica/services/home-assistant.nix`
  - `modules/constellation/tablet-sync.nix` → `hosts/galactica/services/tablet-sync.nix`
  - `modules/constellation/vpn-exit-nodes.nix` → `hosts/galactica/services/vpn-exit-nodes.nix`
  - `modules/constellation/immich-pixel-sync/` → `hosts/galactica/services/immich-pixel-sync/`
  - `modules/constellation/pia.nix` → `hosts/galactica/services/pia.nix`
  - `modules/constellation/pia-ca.rsa.4096.crt` → `hosts/galactica/services/pia-ca.rsa.4096.crt` (read by `pia.nix` as `./pia-ca.rsa.4096.crt`)
  - `modules/services/{media-apps,media-automation,media-streaming,home-apps,network-tools}.nix` → `hosts/galactica/services/`
- Move, basestar:
  - `modules/constellation/k3s.nix` → `hosts/basestar/k3s.nix`
  - `modules/constellation/sites/` → `hosts/basestar/sites/` (contains `arsfeld-dev.nix`, `rosenfeld-one.nix`, `well-known/`)
- Move, raider: `modules/constellation/{project-vms,docker}.nix` → `hosts/raider/`
- Move, pegasus: `modules/constellation/media-sync.nix` → `hosts/pegasus/media-sync.nix`
- Create: `hosts/basestar/sites/default.nix`
- Modify: `hosts/galactica/configuration.nix` (imports), `hosts/galactica/backup/default.nix`, `hosts/galactica/services/default.nix`, `hosts/basestar/configuration.nix` (imports), `hosts/raider/configuration.nix` (imports), `hosts/pegasus/configuration.nix` (imports), `flake-modules/checks.nix:25`, `hosts/basestar/k8s/default.nix:9,31`, `hosts/basestar/k3s.nix:491` (comment)

- [ ] **Step 1: Move the files.**

```bash
G=hosts/galactica
git mv modules/constellation/weekly-deploy.nix $G/weekly-deploy.nix
git mv modules/constellation/rustic.nix $G/backup/rustic.nix
for f in opencloud home-assistant tablet-sync vpn-exit-nodes pia; do
  git mv modules/constellation/$f.nix $G/services/$f.nix
done
git mv modules/constellation/pia-ca.rsa.4096.crt $G/services/pia-ca.rsa.4096.crt
git mv modules/constellation/immich-pixel-sync $G/services/immich-pixel-sync
for f in media-apps media-automation media-streaming home-apps network-tools; do
  git mv modules/services/$f.nix $G/services/$f.nix
done
git mv modules/constellation/k3s.nix hosts/basestar/k3s.nix
git mv modules/constellation/sites hosts/basestar/sites
git mv modules/constellation/project-vms.nix hosts/raider/project-vms.nix
git mv modules/constellation/docker.nix hosts/raider/docker.nix
git mv modules/constellation/media-sync.nix hosts/pegasus/media-sync.nix
ls modules/services 2>/dev/null; echo "modules/services gone: $?"   # expect non-zero (directory gone)
```
If `modules/constellation/immich-pixel-sync/__pycache__` (untracked) is left behind, delete it: `rm -rf modules/constellation/immich-pixel-sync`.

- [ ] **Step 2: Create `hosts/basestar/sites/default.nix`.**

```nix
{
  imports = [
    ./arsfeld-dev.nix
    ./rosenfeld-one.nix
  ];
}
```
Then `git add -N hosts/basestar/sites/default.nix`.

- [ ] **Step 3: Wire imports.**

`hosts/galactica/configuration.nix` — add to `imports` after `./scripts`:
```nix
    ./weekly-deploy.nix
```

`hosts/galactica/backup/default.nix` — add `./rustic.nix` to its `imports` list (keep alphabetical with the existing entries).

`hosts/galactica/services/default.nix` — add these entries to the `imports` list, each at its alphabetical position:
```nix
    ./home-apps.nix
    ./home-assistant.nix
    ./immich-pixel-sync
    ./media-apps.nix
    ./media-automation.nix
    ./media-streaming.nix
    ./network-tools.nix
    ./opencloud.nix
    ./pia.nix
    ./tablet-sync.nix
    ./vpn-exit-nodes.nix
```

`hosts/basestar/configuration.nix` — add to `imports` after `./k8s`:
```nix
    ./k3s.nix
    ./sites
```

`hosts/raider/configuration.nix` — add to `imports` after `./samba.nix`:
```nix
    ./docker.nix
    ./project-vms.nix
```

`hosts/pegasus/configuration.nix` — add to `imports` after `./backup`:
```nix
    ./media-sync.nix
```

- [ ] **Step 4: Fix path references.**

`flake-modules/checks.nix:25`:
```nix
            cp ${../hosts/galactica/services/immich-pixel-sync}/*.py .
```
(The store path's name is still `immich-pixel-sync` and the tracked content is identical, so `immich-pixel-sync-test` must compare `same`.)

Comments — replace old paths with new ones:
- `hosts/basestar/k8s/default.nix:9` and `:31`: `modules/constellation/k3s.nix` → `hosts/basestar/k3s.nix`
- `hosts/basestar/k3s.nix:491`: `modules/constellation/sites/arsfeld-dev.nix` → `hosts/basestar/sites/arsfeld-dev.nix`

Then confirm no stale code/comment references remain outside `docs/`:
```bash
grep -rnE "modules/constellation/(weekly-deploy|rustic|opencloud|home-assistant|tablet-sync|vpn-exit-nodes|immich-pixel-sync|pia|k3s|sites|project-vms|docker|media-sync)|modules/services/" \
  --include=*.nix --include=*.sh --include=*.py --include=justfile --include=*.just --include=*.yml . | grep -v "^./docs/"
```
Expected: no output. (CLAUDE.md is handled in Task 4.)

- [ ] **Step 5:** `just fmt`, then `$S/snapshot.sh $S/t2 && $S/compare.sh $S/base $S/t2` — apply the acceptance rule.
- [ ] **Step 6: Commit.**

```bash
git add hosts/basestar/sites/default.nix hosts/galactica/configuration.nix hosts/galactica/backup/default.nix \
  hosts/galactica/services/default.nix hosts/basestar/configuration.nix hosts/pegasus/configuration.nix \
  flake-modules/checks.nix hosts/basestar/k8s/default.nix hosts/basestar/k3s.nix hosts/raider/configuration.nix
git status --short   # everything staged, nothing left ' M'
git commit -m "refactor(modules): move host-only modules into their hosts"
```
Verify with `git show --stat HEAD` that the moves show as renames (`R100`).

---

### Task 3: Drop enable flags from host-local modules

Mechanical rule, applied to each file below: delete the `enable` option; replace `config = mkIf cfg.enable {` (or the `lib.`/`config.constellation.<x>.enable` spelling) with `config = {` — the body keeps its indentation, so the diff stays small; if the `options.constellation.<x>` attrset is left empty, delete it; if `cfg` is then unused, delete its `let` binding; delete the host's `enable = true;`.

**Files and exact edits** (line numbers are from before Task 3; they shift within a file as you edit, so match on text):

| File | Delete | `config` line becomes |
|---|---|---|
| `hosts/galactica/weekly-deploy.nix` | `    enable = mkEnableOption "weekly tier-1 update, deploy and health report";` (558) | 595: `  config = {` |
| `hosts/galactica/backup/rustic.nix` | `    enable = mkEnableOption "rustic backup profiles (cold-storage tier)";` (259) | 294: `  config = {` |
| `hosts/galactica/services/opencloud.nix` | the 9-line `enable = mkOption { … default = false; };` block (39–47) | 84: `  config = {` |
| `hosts/galactica/services/home-assistant.nix` | the whole `options.constellation.home-assistant = { enable = …; };` block (31–42) | 43: `  config = {` |
| `hosts/galactica/services/tablet-sync.nix` | the 8-line `enable = mkOption { … };` block (244–251) and the blank line after it | 311: `  config = {` |
| `hosts/galactica/services/immich-pixel-sync/default.nix` | `    enable = mkEnableOption "staging recent Immich assets for a Pixel via Syncthing";` (54) | 172: `  config = {` |
| `hosts/galactica/services/pia.nix` | `    enable = mkEnableOption "PIA VPN namespace with dynamic port forwarding";` (401) | 485: `  config = {` |
| `hosts/galactica/services/media-streaming.nix` | `  cfg = config.constellation.mediaStreaming;` and the `options.constellation.mediaStreaming.enable = …;` line plus the blank line after it | `  config = {` |
| `hosts/galactica/services/media-automation.nix` | `cfg = config.constellation.mediaAutomation;`, the `options…enable` line + following blank | `  config = {` |
| `hosts/galactica/services/home-apps.nix` | `cfg = config.constellation.homeApps;`, the `options…enable` line + following blank | `  config = {` |
| `hosts/galactica/services/network-tools.nix` | `cfg = config.constellation.networkTools;`, the `options…enable` line + following blank | `  config = {` |
| `hosts/galactica/services/media-apps.nix` | `cfg = config.constellation.mediaApps;`, the `options…enable` line + following blank | `  config = lib.mkMerge [` — and its closing `  ]);` (line 108) becomes `  ];` |
| `hosts/basestar/k3s.nix` | `    enable = mkEnableOption "single-node k3s cluster alongside the host's Caddy";` (18) | 108: `  config = {` |
| `hosts/basestar/sites/arsfeld-dev.nix` | the `options.constellation.sites.arsfeld-dev = { enable = …; };` block (8–10) and blank after | 12: `  config = {` |
| `hosts/basestar/sites/rosenfeld-one.nix` | `    enable = lib.mkEnableOption "rosenfeld-one";` (15) | 28: `  config = {` |
| `hosts/raider/project-vms.nix` | `    enable = mkEnableOption "project isolation VMs with Debian testing";` (547) — **not** the per-VM `enable` at line 52 | 613: `  config = {` |
| `hosts/raider/docker.nix` | the whole `options.constellation.docker = { enable = …; };` block (24–35) | 36: `  config = {` |

**Not changed:** `hosts/galactica/services/vpn-exit-nodes.nix` and `hosts/pegasus/media-sync.nix` keep their `enable` (both are configured with `enable = false`).

**Host-side edits:**
- `hosts/galactica/configuration.nix`:
  - delete the five `constellation.{mediaStreaming,mediaAutomation,mediaApps,homeApps,networkTools}.enable = true;` lines and the `# Service modules (migrated from constellation.media)` comment above them;
  - delete `constellation.home-assistant.enable = true;` and its comment;
  - delete `constellation.tabletSync.enable = true;` and its two comment lines;
  - delete `constellation.opencloud.enable = true;` and its comment;
  - delete `constellation.weeklyDeploy.enable = true;` and move its three-line comment (`# galactica is the only always-on x86 host …`) to sit directly above `./weekly-deploy.nix` in `imports`;
  - in `constellation.immichPixelSync = {`, delete `enable = true;`;
  - the comment `# Enable Transmission confined to the PIA VPN namespace (enables constellation.pia)` → `# Enable Transmission confined to the PIA VPN namespace (constellation.pia)`.
- `hosts/galactica/backup/rustic-ovh.nix`: in `constellation.rustic = {`, delete `enable = true;` and the blank line after it.
- `hosts/galactica/services/transmission-vpn.nix`: in `constellation.pia = {`, delete `enable = true;`.
- `hosts/basestar/configuration.nix`: in `constellation.k3s = {`, delete `enable = true;`; delete `constellation.sites.arsfeld-dev.enable = true;`; in `constellation.sites.rosenfeld-one = {`, delete `enable = true;`.
- `hosts/raider/configuration.nix`: delete `    docker.enable = true; # Enable Docker runtime` inside `constellation = {`; in `constellation.projectVms = {`, delete `enable = true;`.
- `hosts/pegasus/configuration.nix`: replace the comment block above `constellation.mediaSync.enable = false;` (starts `# mediaSync is DISABLED for the duration of the move.`) with:

```nix
  # mediaSync stays DISABLED until its cleanup is fixed.
  #
  # Cleanup deletes any unmarked *directory* under /mnt/storage/media, and
  # when galactica is unreachable the remote marker scan fails, so the "keep"
  # set is empty and a nightly run would wipe every synced directory. Before
  # re-enabling: make cleanup a no-op when the scan fails, and re-mark (or
  # relocate) the Vault subdirectories the one-off rsync created during the
  # galactica move, or the first managed run deletes them.
```
  Also update the reference at `hosts/pegasus/configuration.nix:39` (`# mediaSync disabled for the move, …`) to read `# mediaSync is disabled (see below), …`, keeping the rest of that comment.

- [ ] **Step 1:** Apply the module edits in the table.
- [ ] **Step 2:** Apply the host-side edits.
- [ ] **Step 3: Confirm no dropped option is still set or read anywhere.**

```bash
grep -rnE "constellation\.(weeklyDeploy|rustic|opencloud|home-assistant|tabletSync|immichPixelSync|pia|k3s|projectVms|docker|homeApps|mediaApps|mediaAutomation|mediaStreaming|networkTools|sites\.arsfeld-dev|sites\.rosenfeld-one)\.enable|cfg\.enable" \
  hosts modules flake-modules --include=*.nix
```
Expected: only lines in `hosts/galactica/services/vpn-exit-nodes.nix` and `hosts/pegasus/media-sync.nix` (both keep `cfg.enable`), plus `modules/media/__utils.nix:74` (unrelated `cfg.enable` on media services). Also grep the nested forms: `grep -n "enable = true" hosts/basestar/configuration.nix hosts/galactica/backup/rustic-ovh.nix hosts/galactica/services/transmission-vpn.nix` and check each remaining hit belongs to an unrelated option.

- [ ] **Step 4:** `just fmt`, then `$S/snapshot.sh $S/t3 && $S/compare.sh $S/base $S/t3` — apply the acceptance rule. This is the step most likely to fail: an evaluation error `The option 'constellation.<x>.enable' does not exist` means a host line was missed; a unit-level diff means an unwrap changed semantics.
- [ ] **Step 5: Commit.**

```bash
git add hosts/galactica hosts/basestar hosts/pegasus/configuration.nix hosts/raider
git status --short   # nothing left unstaged
git commit -m "refactor(modules): drop enable flags from host-local modules"
```

---

### Task 4: Document the rule in CLAUDE.md

**Files:** Modify `CLAUDE.md`

- [ ] **Step 1: Module Auto-Discovery.** Replace the paragraph starting `All \`.nix\` files under \`modules/\` are loaded automatically by haumea` with:

```markdown
All `.nix` files under `modules/` are loaded automatically by haumea into every host — no
explicit imports needed. That makes `modules/` the place for code **more than one host
uses**, switched on per host with `constellation.<module>.enable = true`.

**Code only one host uses lives in `hosts/<host>/`, and importing it is what turns it on** —
no `enable` flag unless the host genuinely toggles it (pegasus's `media-sync` and
galactica's `vpn-exit-nodes` do; both are configured with `enable = false`). Options that
carry values keep their `constellation.*` names even when the module is host-local
(`constellation.k3s.domains`, `constellation.pia.consumers`, …). A shared module must never
read a host-local option: it would fail to evaluate on every other host. When a module
gains its second user, move it to `modules/constellation/` and give it an `enable` flag.
```

- [ ] **Step 2: Constellation module table.** Replace the table under `### Constellation Modules (\`modules/constellation/\`)` with:

```markdown
| Module | Purpose |
|--------|---------|
| `common.nix` | Base config: Nix flakes, caches, SSH, Tailscale, Avahi (on by default) |
| `users.nix` | User accounts, SSH keys, sudo |
| `sops.nix` | sops-nix infrastructure (age keys, default paths) |
| `podman.nix` | Container runtime |
| `backrest.nix` | restic backups via Backrest |
| `backup-notify.nix` / `backup-status.nix` | Backup notification and status helpers, enabled by `backrest` and galactica's `rustic` |
| `email.nix` | Outgoing mail settings, read by `systemd-email-notify` |
| `netdata-client.nix` | Netdata agent |
| `forgejo-runner.nix` | Forgejo Actions runner |
| `virtualization.nix` | KVM/libvirt |
| `development.nix` | Dev tools (Node, Python, Go, Rust, …) |
| `desktop.nix` | Desktop environment (`variant` selects GNOME etc.) |
| `gaming.nix` | Gaming environment |

Host-local modules (see the rule above): galactica — `weekly-deploy.nix`,
`backup/rustic.nix`, and under `services/` `pia`, `opencloud`, `home-assistant`,
`tablet-sync`, `vpn-exit-nodes`, `immich-pixel-sync/`, `media-apps`, `media-automation`,
`media-streaming`, `home-apps`, `network-tools`; basestar — `k3s.nix`, `sites/`;
raider — `docker.nix`, `project-vms.nix`; pegasus — `media-sync.nix`.
```

- [ ] **Step 3: Fix moved paths.** In `CLAUDE.md`:
  - every `modules/constellation/k3s.nix` → `hosts/basestar/k3s.nix` (k3s section);
  - `After changing \`weekly-deploy.nix\`` → `After changing \`hosts/galactica/weekly-deploy.nix\``;
  - the k3s sentence "`modules/` is haumea-loaded for every host in the fleet and these manifests belong to one" stays — it is now an instance of the rule.

  Then: `grep -nE "modules/constellation/(k3s|weekly-deploy|rustic|pia|sites|docker|project-vms|media-sync)|modules/services|metrics-client|observability-hub|cosmic\.nix|niri\.nix" CLAUDE.md` — expected: no output.

- [ ] **Step 4: Commit.**

```bash
git commit -m "docs: document the shared-vs-host module rule" -- CLAUDE.md
```

---

### Task 5: Final check

- [ ] **Step 1:** `$S/snapshot.sh $S/final && $S/compare.sh $S/base $S/final` — acceptance rule.
- [ ] **Step 2:** `nix flake check --no-build` — expect success (evaluates `pre-commit-check` and everything else).
- [ ] **Step 3:** `git status --short` — expect no output.
- [ ] **Step 4:** `git log --oneline -5` — the four commits in order. Do not push unless the user asks.
