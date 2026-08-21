# Deploy Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace colmena with a two-phase `just deploy` — `nix-fast-build` for parallel evaluation, building and attic push, then `nixos-rebuild --store-path` for parallel activation — so every deploy path in the repo evaluates the same `.#nixosConfigurations`.

**Architecture:** A new `flake.deployTargets` output maps each host to `nixosConfigurations.<host>.config.system.build.toplevel`. `just` expands `@tier` selectors, runs `nix-fast-build` over the selected subset (barrier: nothing activates unless everything builds), then activates each host in parallel from the pre-built closure. Colmena and deploy-rs are removed entirely.

**Tech Stack:** Nix flakes + flake-parts, `nix-fast-build` 1.6.0, `nix-eval-jobs` (from the `det-nix-eval-jobs` input), `nixos-rebuild-ng` 26.11, `just`, attic, Tailscale SSH.

**Spec:** `docs/superpowers/specs/2026-08-20-deploy-pipeline-design.md`

## Global Constraints

- Commit straight to `master`. No feature branches, no worktrees — the weekly routine deploy reverts branch-only config.
- Conventional commits: `<type>(<scope>): <subject>`. Scopes in use for these files: `modules`, `flake`, `justfile`, `dev`, `docs`. Never mention Claude in a commit message or as author.
- Run `just fmt` (alejandra) before every commit that touches a `.nix` file. `format.yml` fails CI on unformatted Nix.
- All hosts are reached at `<hostname>.bat-boa.ts.net` as `root` over Tailscale SSH.
- Tier 1 is `basestar`, `galactica`, `raider`, defined by `tiers` in `flake-modules/hosts.nix`.
- `basestar` is `aarch64-linux`; every other host in play is `x86_64-linux`. `nix-fast-build --systems` must name both or basestar is silently dropped.
- Never pass `--skip-cached` to `nix-fast-build` in the deploy path: it makes `nix-eval-jobs` skip already-cached attributes outright, leaving no local store path for `--store-path`.
- Every verification snippet in this plan is **bash**. The login shell on these machines is fish,
  so run them as `bash -c '...'` (or `nix develop -c bash -c '...'`) rather than pasting them raw.
- Watch peak memory during the first full-tier build. `nix-fast-build` runs one nix-eval-jobs worker
  per attribute; if three concurrent evaluations strain the deploy host, bound them with
  `--eval-workers` / `--eval-max-memory-size` rather than serialising the phase.
- `weekly-deploy` (`modules/constellation/weekly-deploy.nix`) is out of scope and must not be edited. It already deploys `.#nixosConfigurations` with `max-jobs = 0`.
- Do not push to `origin` until Task 7 passes. `weekly-deploy` can only deploy a commit CI has already built and pushed to attic.

## File Structure

| File | Change | Responsibility after this plan |
|---|---|---|
| `modules/constellation/gaming.nix` | Modify (lines 3–7, 534–556) | Picks `services.scx-loader` or `services.scx` depending on the host's channel |
| `flake-modules/deploy.nix` | Rewrite | Defines `flake.deployTargets` only. deploy-rs config deleted |
| `flake-modules/colmena.nix` | Delete | — |
| `flake-modules/dev.nix` | Modify (lines 44–51) | Dev shell ships `nix-fast-build`, not colmena/deploy-rs |
| `flake.nix` | Modify (line 14, line 43) | Drops the `deploy-rs` input and the `colmena.nix` import |
| `justfile` | Modify (lines 9, 15–163) | Holds `_hosts` and `_apply` plus the public deploy recipes |
| `CLAUDE.md` | Modify (lines 16–33, 99–118) | Documents the new deploy commands and the single-evaluation-path invariant |
| `README.md` | Modify (lines 42–47, 89–90, 129) | Tier table, repo layout, tooling list |

**Deviation from the spec:** the spec's Section 2 proposed `just/deploy.just`. That will not work — `just`'s `mod` directive namespaces a module's recipes, so `mod deploy 'just/deploy.just'` makes `just deploy galactica` parse `deploy` as the module and `galactica` as a recipe inside it. The recipes stay in the root `justfile`, where the current colmena recipes already live.

---

### Task 1: Unblock blackbird's evaluation

`services.scx-loader` exists only in nixpkgs-unstable. `blackbird` enables `constellation.gaming` on stable, so its whole configuration fails to evaluate — and because `flake-modules/colmena.nix:66-73` force-evaluates every host, that failure currently breaks *all* colmena deploys. This task must land first: every later task's verification evaluates hosts.

Stable's `services.scx` (`nixos/modules/services/scheduling/scx.nix`) has `scheduler` typed as `lib.types.enum cfg.package.schedulers`, and `pkgs.scx.full.schedulers` on 26.05 contains `scx_lavd`, `scx_bpfland` and `scx_rusty` — the exact three values `constellation.gaming.scheduler` maps to.

**Files:**
- Modify: `modules/constellation/gaming.nix:3-7` (module arguments), `modules/constellation/gaming.nix:534-556` (the `services` block tail)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `nix build .#nixosConfigurations.blackbird.config.system.build.toplevel` succeeds. Later tasks depend on every host in `self.hosts` evaluating.

- [ ] **Step 1: Run the verification and watch it fail**

```bash
nix eval --raw .#nixosConfigurations.blackbird.config.system.build.toplevel.drvPath
```

Expected: FAIL with ``error: The option `services.scx-loader' does not exist.`` and a trace pointing at `modules/constellation/gaming.nix`.

- [ ] **Step 2: Confirm raider (unstable) is unaffected, so you have a before/after baseline**

```bash
nix eval --raw .#nixosConfigurations.raider.config.system.build.toplevel.drvPath
```

Expected: PASS, printing a `/nix/store/...-nixos-system-raider-....drv` path. Write it down — Step 6 checks it is unchanged.

- [ ] **Step 3: Add `options` to the module arguments**

In `modules/constellation/gaming.nix`, change the header from:

```nix
{
  config,
  pkgs,
  lib,
  ...
}: let
```

to:

```nix
{
  config,
  options,
  pkgs,
  lib,
  ...
}: let
```

- [ ] **Step 4: Move the scheduler definition out of the `services` attrset and make it channel-aware**

Delete lines 534–551 (the `sched_ext BPF scheduler` comment block, the `scx-loader = lib.mkIf (...) { ... };` definition, and the blank line after it) from inside `services = { ... }`. The block being deleted is:

```nix
      # sched_ext BPF scheduler (replaces the old system76-scheduler, which
      # caused high context switches and freezing). scx_lavd is CachyOS/Bazzite's
      # default for mixed desktop + dev + gaming workloads. Auto-falls back to
      # CFS if the BPF program errors. Requires kernel >= 6.12 (xanmod_latest).
      #
      # scx-loader rather than the static services.scx: same daemon, same
      # default scheduler, but it also owns org.scx.Loader on the system bus so
      # the scheduler can be switched at runtime. We deliberately do NOT switch
      # to its Gaming mode from the gamemode hook — scx_lavd's default is
      # already --autopilot (it picks performance/powersave/balanced from load,
      # and is mutually exclusive with the --performance that Gaming mode would
      # pass), so switching would mostly duplicate autopilot while costing a BPF
      # unload/reload stall at both game start and exit.
      scx-loader = lib.mkIf (cfg.scheduler != "none") {
        enable = true;
        config.default_sched = "scx_${cfg.scheduler}";
      };

```

Then replace the closing `};` of the `services` attrset (the line reading exactly four spaces followed by `};`, immediately after the `tlp` block) with:

```nix
    }
    # sched_ext BPF scheduler (replaces the old system76-scheduler, which
    # caused high context switches and freezing). scx_lavd is CachyOS/Bazzite's
    # default for mixed desktop + dev + gaming workloads. Auto-falls back to
    # CFS if the BPF program errors. Requires kernel >= 6.12 (xanmod_latest).
    #
    # scx-loader rather than the static services.scx: same daemon, same default
    # scheduler, but it also owns org.scx.Loader on the system bus so the
    # scheduler can be switched at runtime. We deliberately do NOT switch to its
    # Gaming mode from the gamemode hook — scx_lavd's default is already
    # --autopilot (it picks performance/powersave/balanced from load, and is
    # mutually exclusive with the --performance that Gaming mode would pass), so
    # switching would mostly duplicate autopilot while costing a BPF
    # unload/reload stall at both game start and exit.
    #
    # scx-loader landed in nixpkgs after 26.05, so it exists only for hosts in
    # `unstableHosts`. Hosts on stable fall back to services.scx: same daemon,
    # same scheduler, minus the org.scx.Loader D-Bus interface. This has to be
    # an `optionalAttrs` on the option's existence rather than `lib.mkIf`,
    # because unknown-option checking runs on the definition *path* — a
    # `mkIf false` on services.scx-loader still fails to evaluate on stable.
    // lib.optionalAttrs (cfg.scheduler != "none") (
      if options.services ? scx-loader
      then {
        scx-loader = {
          enable = true;
          config.default_sched = "scx_${cfg.scheduler}";
        };
      }
      else {
        scx = {
          enable = true;
          scheduler = "scx_${cfg.scheduler}";
        };
      }
    );
```

- [ ] **Step 5: Format**

```bash
just fmt
```

- [ ] **Step 6: Verify blackbird now evaluates and raider is byte-identical**

```bash
nix eval --raw .#nixosConfigurations.blackbird.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.raider.config.system.build.toplevel.drvPath
```

Expected: both PASS. raider's `.drv` path must be **exactly** the one recorded in Step 2 — raider is on unstable, so it still takes the `scx-loader` branch and nothing about it may change.

- [ ] **Step 7: Verify the fallback actually wired up on blackbird**

```bash
nix eval --json .#nixosConfigurations.blackbird.config.services.scx
```

Expected: JSON containing `"enable":true` and `"scheduler":"scx_lavd"` (blackbird sets no explicit `scheduler`, so it gets the `lavd` default).

- [ ] **Step 8: Commit**

```bash
git add modules/constellation/gaming.nix
git commit -m "fix(modules): fall back to services.scx on hosts without scx-loader"
```

---

### Task 2: Add `flake.deployTargets` and retire deploy-rs

`flake.deployTargets` is the single output the new driver builds. It is deliberately a thin `mapAttrs` over `nixosConfigurations` so that `just deploy`, the CI matrix and `weekly-deploy` all realise identical derivations.

deploy-rs comes out in the same task because it lives in the file being rewritten. Its Nix 2.32 bug is fixed upstream, but it deploys nodes sequentially and so does not solve the problem this work exists for.

**Files:**
- Rewrite: `flake-modules/deploy.nix`
- Modify: `flake.nix:14` (drop the `deploy-rs` input), `flake-modules/dev.nix:50` (drop the deploy-rs package)
- Modify: `justfile` — delete the `boot-rs`, `deploy-rs` and `trace-rs` recipes (lines 127–167) plus their two exclusive helpers: `args := "--skip-checks"` (line 9) and `_format-targets` (lines 12–15)

**Interfaces:**
- Consumes: Task 1's guarantee that every host evaluates.
- Produces: `flake.deployTargets.<host>` — a derivation per host, keyed by the same names as `self.hosts`. Task 3 and Task 4 build `.#deployTargets` and `.#deployTargets.<host>`.

- [ ] **Step 1: Write the verification and watch it fail**

```bash
nix eval --raw .#deployTargets.raider.drvPath
```

Expected: FAIL with `error: flake 'git+file:///home/arosenfeld/Code/nixos' does not provide attribute ... 'deployTargets'`.

- [ ] **Step 2: Replace `flake-modules/deploy.nix` entirely**

```nix
{self, ...}: {
  # Buildable system closures keyed by host. This deliberately *is*
  # nixosConfigurations, so `just deploy`, the CI matrix and weekly-deploy all
  # realise identical derivation paths — which is why substitution always hits.
  #
  # Do not reintroduce a second evaluation that calls `import inputs.nixpkgs`
  # itself: that loses the flake revision and yields `…-26.05pre-git`
  # derivations nothing has ever built. That is what broke colmena.
  flake.deployTargets =
    builtins.mapAttrs (_: c: c.config.system.build.toplevel) self.nixosConfigurations;
}
```

- [ ] **Step 3: Drop the deploy-rs input**

In `flake.nix`, delete these two lines (currently line 14 and the line after it):

```nix
    deploy-rs.url = "github:serokell/deploy-rs"; # Remote deployment tool
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
```

Leave `./flake-modules/deploy.nix` in the `imports` list — the file still exists, it just holds `deployTargets` now.

- [ ] **Step 4: Drop deploy-rs from the dev shell**

In `flake-modules/dev.nix`, delete this line:

```nix
          inputs.deploy-rs.packages."${pkgs.stdenv.hostPlatform.system}".default
```

- [ ] **Step 5: Delete the deploy-rs just recipes**

In `justfile`, delete the entire `=== Deploy-rs Deployment (currently broken with Nix 2.32+) ===` section — the header comment, the `NOTE:` line, and the `boot-rs`, `deploy-rs` and `trace-rs` recipes. Those three were the only consumers of two other definitions near the top of the file; delete both:

```just
args := "--skip-checks"
```

```just
# Private recipe to format targets with .# prefix
_format-targets +TARGETS:
    #!/usr/bin/env bash
    printf ".#%s " {{ TARGETS }} | sed 's/ $//'
```

Confirm nothing else used them before deleting: `grep -n '{{ args }}\|_format-targets' justfile` must return no hits afterwards.

Also update the `ssh` comment in `flake-modules/dev.nix` (currently "so colmena/deploy-rs resolve it here") — leave the `openssh` package in place, it is still needed, but change the first line of its comment to:

```nix
          # Provide ssh from the dev shell so the deploy driver resolves it here
```

- [ ] **Step 6: Format and refresh the lock**

```bash
just fmt
nix flake lock
```

Expected: `nix flake lock` removes the `deploy-rs` node (and its now-unreferenced transitive inputs) from `flake.lock`.

- [ ] **Step 7: Verify `deployTargets` matches `nixosConfigurations` exactly**

```bash
for h in galactica basestar raider blackbird; do
  a=$(nix eval --raw ".#deployTargets.$h.drvPath")
  b=$(nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath")
  [ "$a" = "$b" ] && echo "$h OK" || echo "$h MISMATCH: $a != $b"
done
```

Expected: four `OK` lines. This is the single-evaluation-path claim, checked directly.

- [ ] **Step 8: Verify nothing still references deploy-rs**

```bash
grep -rn "deploy-rs\|deploy_rs" --include='*.nix' --include=justfile --include='*.just' . | grep -v '^./docs/'
```

Expected: no output. (Docs still mention it; Task 6 fixes those.)

- [ ] **Step 9: Commit**

```bash
git add flake.nix flake.lock flake-modules/deploy.nix flake-modules/dev.nix justfile
git commit -m "feat(flake): add deployTargets output and drop deploy-rs"
```

---

### Task 3: Put `nix-fast-build` in the dev shell

nixpkgs ships `nix-fast-build` 1.6.0 bundling `nix-eval-jobs` 2.35, while these machines run Determinate Nix 2.34.8. The existing colmena entry already overrides `nix-eval-jobs` with the `det-nix-eval-jobs` input for exactly this reason; the same override moves to `nix-fast-build`. `nix-fast-build.override.__functionArgs` confirms `nix-eval-jobs` is an overridable argument.

**Files:**
- Modify: `flake-modules/dev.nix:44-49` (add `nix-fast-build`, keep the colmena entry for now)

**Interfaces:**
- Consumes: `flake.deployTargets` from Task 2.
- Produces: `nix-fast-build` on `PATH` inside `nix develop`. Task 4's `_apply` recipe invokes it.

- [ ] **Step 1: Confirm nix-fast-build is not yet available**

```bash
nix develop -c sh -c 'command -v nix-fast-build || echo ABSENT'
```

Expected: `ABSENT`.

- [ ] **Step 2: Add the overridden package to the dev shell**

In `flake-modules/dev.nix`, inside `buildInputs`, directly after the existing `(colmena.override { ... })` block, add:

```nix
          # nixpkgs ships nix-fast-build bundling nix-eval-jobs built against
          # upstream nix, while these machines run Determinate Nix. Override it
          # with the matching det-nix-eval-jobs, same as the colmena entry above.
          (nix-fast-build.override {
            nix-eval-jobs = inputs.det-nix-eval-jobs.packages.${system}.default;
          })
```

Colmena stays in the shell for now — it is the fallback while Task 4 is being tested, and Task 5 removes it.

- [ ] **Step 3: Format**

```bash
just fmt
```

- [ ] **Step 4: Verify the binary resolves**

```bash
nix develop -c nix-fast-build --help | head -3
```

Expected: the `usage: nix-fast-build [-h] ...` banner.

- [ ] **Step 5: Verify phase 1 works standalone against a single host**

```bash
out=$(mktemp -d)
nix develop -c nix-fast-build \
  --flake '.#deployTargets' \
  --select 't: { inherit (t) raider; }' \
  --systems "x86_64-linux aarch64-linux" \
  --out-link "$out/result"
readlink -f "$out/result-raider"
```

Expected: the build completes and `readlink` prints a `/nix/store/...-nixos-system-raider-...` path (no `.drv` suffix). Note `--attic-cache` is deliberately omitted here — this step tests eval and build only.

- [ ] **Step 6: Verify the multi-host, multi-architecture selection**

```bash
out=$(mktemp -d)
nix develop -c nix-fast-build \
  --flake '.#deployTargets' \
  --select 't: { inherit (t) galactica basestar raider; }' \
  --systems "x86_64-linux aarch64-linux" \
  --out-link "$out/result"
ls "$out"
```

Expected: three symlinks — `result-galactica`, `result-basestar`, `result-raider`. If `result-basestar` is missing, `--systems` was wrong: `nix-fast-build` drops attributes whose `system` is not listed, without an error.

- [ ] **Step 7: Commit**

```bash
git add flake-modules/dev.nix
git commit -m "feat(dev): add nix-fast-build to the dev shell"
```

---

### Task 4: Replace the colmena recipes with the two-phase driver

**Files:**
- Modify: `justfile` — replace the `=== Colmena Deployment (default) ===` section (the `deploy`, `boot`, `test`, `deploy-all`, `reboot` and `info` recipes) and update `_poke-targets` and `build`/`cache`

**Interfaces:**
- Consumes: `flake.deployTargets` (Task 2), `nix-fast-build` on `PATH` (Task 3), `flake.tiers` (already exists in `flake-modules/hosts.nix`).
- Produces: `just _hosts <targets...>` (expands `@tier` selectors to newline-separated hostnames) and `just _apply <action> <targets...>`, plus `just deploy`, `just boot`, `just test`, `just dry-run`, `just reboot`, `just deploy-all`, `just build`, `just cache`, `just info`.

- [ ] **Step 1: Record the current behaviour you are replacing**

```bash
just --list | head -30
```

Expected: the current recipe list. Keep it — Step 7 diffs against it to confirm no recipe was dropped by accident.

- [ ] **Step 2: Replace the colmena section of the `justfile`**

Delete everything from the `# === Colmena Deployment (default) ===` header through the end of the `info` recipe, and put this in its place:

```just
# === Deployment ===
# Phase 1 builds every named host in parallel and pushes to attic; phase 2
# activates each host in parallel from the pre-built closure. Nothing activates
# unless everything builds.

# Expand @tier selectors to hostnames; bare names pass through. Deduped, one
# per line. Every recipe that takes targets routes through this, so tier
# selectors work everywhere and the expansion lives in exactly one place.
_hosts +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail
    for t in {{ TARGETS }}; do
      case "$t" in
        @*) nix eval --json ".#tiers.${t#@}" | jq -r '.[]' ;;
        *)  echo "$t" ;;
      esac
    done | sort -u

# Private recipe backing deploy/boot/test/dry-run.
_apply ACTION +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail

    hosts=$(just _hosts {{ TARGETS }} | tr '\n' ' ')

    echo "==> {{ ACTION }}: ${hosts}"
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT

    # Phase 1 — parallel eval (one nix-eval-jobs worker per attr), parallel
    # build, attic push. Two flags are load-bearing:
    #   --systems must name both. The default is the local system only, and
    #     nix-fast-build silently drops attrs for any other system, which would
    #     skip basestar (aarch64) entirely.
    #   Do NOT add --skip-cached. It makes nix-eval-jobs skip already-cached
    #     attrs outright, leaving no local store path for --store-path below.
    nix-fast-build \
      --flake '.#deployTargets' \
      --select "t: { inherit (t) ${hosts}; }" \
      --systems "x86_64-linux aarch64-linux" \
      --attic-cache system \
      --out-link "$out/result"

    # Phase 2 — activate in parallel from the pre-built closures. No re-eval.
    #
    # Each host runs inside a subshell that re-raises PIPESTATUS[0]. Without
    # that, `cmd | sed &` makes $! the PID of *sed*, and `wait` would report
    # sed's exit status — masking every failed activation as a success.
    pids=()
    for h in ${hosts}; do
      p=$(readlink -f "$out/result-$h")
      if [ "$h" = "$(hostname)" ]; then
        # Tailscale SSH cannot authenticate a host connecting to itself, so a
        # machine can never deploy itself over --target-host. This branch is
        # what `colmena apply-local` used to be.
        ( sudo nixos-rebuild {{ ACTION }} --store-path "$p" 2>&1 \
            | sed "s/^/[$h] /"; exit "${PIPESTATUS[0]}" ) &
      else
        ( nixos-rebuild {{ ACTION }} --store-path "$p" \
            --target-host "root@$h.bat-boa.ts.net" --use-substitutes 2>&1 \
            | sed "s/^/[$h] /"; exit "${PIPESTATUS[0]}" ) &
      fi
      pids+=($!)
    done
    rc=0
    for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
    exit $rc

# Deploy to one or more hosts. Accepts hostnames and @tier selectors:
#   just deploy galactica raider
#   just deploy @tier1
deploy +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail
    just _apply switch {{ TARGETS }}
    # Poke the expanded hostnames. Passing {{ TARGETS }} straight through would
    # hand `_poke-targets` a literal "@tier1" and ssh to root@@tier1....
    just _poke-targets $(just _hosts {{ TARGETS }} | tr '\n' ' ')

# Deploy with boot activation (takes effect on next reboot)
boot +TARGETS:
    just _apply boot {{ TARGETS }}

# Activate without making it the boot default
test +TARGETS:
    just _apply test {{ TARGETS }}

# Build, then report which units would change. Unlike colmena's dry-run this
# does build — in exchange it names the units that would actually restart.
dry-run +TARGETS:
    just _apply dry-activate {{ TARGETS }}

# Deploy to every discovered host
deploy-all:
    #!/usr/bin/env bash
    set -euo pipefail
    just _apply switch $(just info | tr '\n' ' ')
    just _poke-targets

# Deploy with boot activation and reboot (for kernel/bootloader changes).
# nixos-rebuild has no --reboot flag, so the reboot is explicit.
reboot +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail
    just _apply boot {{ TARGETS }}
    for h in $(just _hosts {{ TARGETS }}); do
      echo "Rebooting ${h}..."
      if [ "$h" = "$(hostname)" ]; then
        sudo systemctl reboot
      else
        ssh "root@${h}.bat-boa.ts.net" systemctl reboot || true
      fi
    done

# List all known hosts
info:
    nix eval --json '.#hosts' | jq -r '.[]'
```

- [ ] **Step 3: Teach `_poke-targets` about self-deployment**

`_poke-targets` keeps its existing signature (`*TARGETS`, defaulting to every discovered host) and now always receives already-expanded hostnames from `deploy`. One bug remains in it: it unconditionally SSHes to `<target>.bat-boa.ts.net`, which fails when the target is the machine running `just` — Tailscale SSH cannot authenticate a host to itself. Replace the body of its `for` loop with:

```bash
    for target in "${targets[@]}"; do
        echo "Poking multi-user.target on ${target}..."
        if [ "${target}" = "$(hostname)" ]; then
            sudo systemctl start multi-user.target
        else
            ssh "root@${target}.bat-boa.ts.net" sudo systemctl start multi-user.target
        fi
    done
```

- [ ] **Step 4: Point `build` and `cache` at `deployTargets`**

`.#deployTargets.<HOST>` and `.#nixosConfigurations.<HOST>.config.system.build.toplevel` are the same derivation; the short path is what the rest of the driver uses. Change the `build` recipe to:

```just
build HOST:
    nix build '.#deployTargets.{{ HOST }}'
```

and the two `nix build` / `attic push` lines inside `cache` to:

```bash
    nix build '.#deployTargets.{{ HOST }}' --out-link result-{{ HOST }}
```

leaving the rest of `cache` alone. `cache` stays useful as the one-host "build and push, don't deploy" utility; `deploy` no longer needs it because `--attic-cache` pushes inline.

- [ ] **Step 5: Verify tier expansion before deploying anything**

```bash
just _hosts @tier1
just _hosts @tier1 octopi raider
```

Expected: the first prints `basestar`, `galactica`, `raider`, one per line. The second prints those three plus `octopi`, still sorted and with `raider` appearing once — mixing selectors with bare names and deduping is the whole point of the helper.

- [ ] **Step 6: Verify `just --list` still offers every recipe**

```bash
just --list
```

Expected: `deploy`, `boot`, `test`, `dry-run`, `reboot`, `deploy-all`, `build`, `cache`, `info`, plus the `nr-*` fallbacks and the unrelated recipes. Diff against Step 1's output: `dry-run` should be the only addition and there should be no removals — Task 2 already deleted the `-rs` recipes, and every colmena recipe here is replaced by one of the same name.

- [ ] **Step 7: Verify no recipe still starts `attic watch-store`**

```bash
grep -n "watch-store" justfile
```

Expected: no output. `--attic-cache system` replaces it, along with its background PID bookkeeping, `trap` and `sleep 1`.

- [ ] **Step 8: Dry-run a single remote host end to end**

```bash
nix develop -c just dry-run galactica
```

Expected: phase 1 builds, then a `[galactica]` prefixed list of units that would be restarted. This is the first real exercise of `nixos-rebuild --store-path --target-host --use-substitutes`.

- [ ] **Step 9: Verify the barrier by deploying a good host alongside a broken one**

Temporarily break one host's evaluation. Add a line defining an option that does not exist to the top level of `hosts/octopi/configuration.nix`'s attrset:

```nix
  _deliberate_break_xyz = true;
```

Then run:

```bash
nix develop -c just dry-run galactica octopi ; echo "exit=$?"
```

Expected: `nix-fast-build` fails with ``The option `_deliberate_break_xyz' does not exist``, `exit=1`, and **no** `[galactica]` activation output appears. Revert with `git checkout hosts/octopi/configuration.nix` before continuing.

- [ ] **Step 10: Commit**

```bash
git add justfile
git commit -m "feat(justfile): deploy via nix-fast-build and nixos-rebuild --store-path"
```

---

### Task 5: Remove colmena

**Files:**
- Delete: `flake-modules/colmena.nix`
- Modify: `flake.nix:43` (drop the import), `flake-modules/dev.nix:46-49` (drop the package)

**Interfaces:**
- Consumes: a working `just deploy` from Task 4.
- Produces: nothing new. `flake.colmena` stops existing.

- [ ] **Step 1: Delete the flake module and its import**

```bash
git rm flake-modules/colmena.nix
```

Then remove this line from `flake.nix`'s `imports` list:

```nix
          ./flake-modules/colmena.nix
```

- [ ] **Step 2: Remove colmena from the dev shell**

In `flake-modules/dev.nix`, delete the whole override block:

```nix
          (colmena.override {
            nix = inputs.determinate.inputs.nix.packages.${system}.nix;
            nix-eval-jobs = inputs.det-nix-eval-jobs.packages.${system}.default;
          })
```

Keep the `det-nix-eval-jobs` input in `flake.nix` — Task 3's `nix-fast-build` override consumes it now.

- [ ] **Step 3: Format**

```bash
just fmt
```

- [ ] **Step 4: Verify the flake still evaluates and colmena is gone**

```bash
nix flake show --all-systems 2>&1 | grep -i colmena || echo "colmena absent"
nix eval --raw .#deployTargets.raider.drvPath
```

Expected: `colmena absent`, then raider's `.drv` path — unchanged from Task 1 Step 2, since removing the hive cannot affect `nixosConfigurations`.

- [ ] **Step 5: Verify `det-nix-eval-jobs` is still referenced**

```bash
grep -rn "det-nix-eval-jobs" --include='*.nix' .
```

Expected: two hits — the input declaration in `flake.nix` and the `nix-fast-build.override` in `flake-modules/dev.nix`. If only the declaration remains, Task 3's override was lost.

- [ ] **Step 6: Verify no source file still mentions colmena**

```bash
grep -rn "colmena" --include='*.nix' --include=justfile --include='*.just' . | grep -v '^./docs/'
```

Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add flake.nix flake-modules/dev.nix flake-modules/colmena.nix
git commit -m "refactor(flake): remove colmena"
```

---

### Task 6: Update the documentation

`CLAUDE.md` is loaded into context every session, so a stale deployment section actively misleads. Its long "It deploys `nixosConfigurations`, deliberately, not the colmena hive" warning becomes obsolete the moment colmena is gone — there is no second evaluation left to warn about. Replace it with the invariant that keeps it that way.

**Files:**
- Modify: `CLAUDE.md:16-33` (Deployment section), `CLAUDE.md:50-66` (the three-bullet weekly-deploy warning), `CLAUDE.md:99-118` (Host Tiers and Flake Structure)
- Modify: `README.md:42-47` (tier deploy example), `README.md:89-90` (repo layout), `README.md:129` (tooling list)

**Interfaces:**
- Consumes: the final command surface from Task 4.
- Produces: docs matching the code.

- [ ] **Step 1: Rewrite CLAUDE.md's deployment section**

Replace the `### Deployment (via Colmena, default)` heading and its fenced block, plus the `deploy-rs is available but currently broken...` line, with:

````markdown
### Deployment

```bash
just deploy galactica           # Deploy to one host
just deploy galactica basestar  # Deploy to multiple hosts in parallel
just deploy @tier1              # Deploy a whole tier
just boot @tier1                # Boot activation (next reboot)
just test raider                # Activate without changing the boot default
just dry-run @tier1             # Build, then report which units would change
just reboot galactica           # Deploy and reboot (kernel changes)
just info                       # List all known hosts
```

`just deploy` runs in two phases. Phase 1 is `nix-fast-build` over `.#deployTargets`:
parallel evaluation via nix-eval-jobs, parallel build, and an inline push to attic.
Phase 2 activates each host in parallel with `nixos-rebuild --store-path`, which skips
evaluation and build entirely, and `--use-substitutes`, so each target pulls its own
closure from attic instead of receiving NARs over Tailscale. Phase 1 is a barrier:
nothing activates unless every host builds.

Deploying the machine you are sitting on is handled automatically — Tailscale SSH
cannot authenticate a host connecting to itself, so `_apply` drops `--target-host` and
uses local `sudo` when the target matches `hostname`.

nixos-rebuild fallback (single host, sequential): `just nr-deploy <host>`,
`just nr-boot <host>`, `just nr-test <host>`.

**The invariant:** every deploy path must evaluate `.#nixosConfigurations` and must
never `import inputs.nixpkgs` to build its own package set. Doing so loses the flake's
revision and yields `…-26.05pre-git` derivations that differ from the dated ones CI
builds and caches, so substitution never hits. That is what colmena did, and why it was
removed. `just deploy`, the CI matrix (`ciMatrix`) and `weekly-deploy` all evaluate the
same attribute today; keep it that way.
````

- [ ] **Step 2: Trim the obsolete weekly-deploy warning**

In the "Three things about this that are not obvious" list, delete the third bullet entirely — the one beginning **It deploys `nixosConfigurations`, deliberately, not the colmena hive.** It describes a divergence that no longer exists, and the invariant added in Step 1 covers the rule it was protecting. Change the introductory line from "Three things" to "Two things". Leave the other two bullets untouched.

- [ ] **Step 3: Update CLAUDE.md's Host Tiers section**

Replace the tier paragraph and bullet with:

```markdown
Hosts are grouped into deployment tiers, defined in `flake-modules/hosts.nix` as the `tiers` attribute (also exposed as the `tiers` flake output):

- **tier1** - `galactica`, `basestar`, `raider`. Always on, should always be deployed. Deploy the whole tier with `just deploy @tier1`.

To add or change a tier, edit `tiers` in `flake-modules/hosts.nix`; the `@tier` selectors in the justfile and the README table follow from it. The CI build matrix (`.github/workflows/build.yml`) is derived from the `ciMatrix` flake output (all discovered hosts with auto-detected platform) — it is not tier-gated.
```

- [ ] **Step 4: Update CLAUDE.md's Flake Structure list**

Replace the two lines:

```markdown
- **`deploy.nix`** - deploy-rs configuration for each host
- **`colmena.nix`** - Colmena deployment with cross-compilation support for aarch64
```

with:

```markdown
- **`deploy.nix`** - `deployTargets`: each host's system closure, the attribute `just deploy` builds
```

- [ ] **Step 5: Update the README**

Replace `README.md`'s tier snippet:

````markdown
Tiers are exposed as `@tier` selectors, so you can deploy a whole tier at once:

```bash
just deploy @tier1     # deploy all tier-1 hosts
```
````

In the repo-layout block, replace the two lines for `colmena.nix` and `deploy.nix` with the single line:

```
  deploy.nix           #   deployTargets: per-host system closures
```

In the Tooling list, replace the Colmena bullet with:

```markdown
- [nix-fast-build](https://github.com/Mic92/nix-fast-build) - Parallel evaluation and build for deploys
```

- [ ] **Step 6: Verify the docs no longer contradict the code**

```bash
grep -rn "colmena\|Colmena\|deploy-rs" CLAUDE.md README.md
```

Expected: at most the historical mentions inside the new invariant paragraph ("That is what colmena did, and why it was removed"). No command examples, no repo-layout entries, no tooling bullets.

- [ ] **Step 7: Verify every command in the new docs actually exists**

```bash
just --list | grep -E "^\s+(deploy|boot|test|dry-run|reboot|info|nr-deploy|nr-boot|nr-test)\b"
```

Expected: one line per documented recipe.

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs(modules): document the nix-fast-build deploy pipeline"
```

---

### Task 7: Live verification on tier 1

Everything up to here was evaluated or dry-run. This task actually switches machines, in increasing order of blast radius, and must complete before anything is pushed — `weekly-deploy` can only deploy a commit CI has already built and pushed to attic, so a push that fails CI leaves the fleet stranded on Sunday.

**Files:** none. This is verification only.

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces: a fleet running the new pipeline, and a green CI run.

- [ ] **Step 1: Deploy the local machine, exercising the self-deploy branch**

```bash
nix develop -c just deploy raider
```

Expected: phase 1 builds raider, phase 2 prints `[raider]` output from a local `sudo nixos-rebuild switch --store-path`, then `_poke-targets` pokes `multi-user.target` locally rather than over SSH. (Run this from raider. From any other machine, substitute that machine's hostname.)

- [ ] **Step 2: Confirm the running system is the closure that was built**

```bash
readlink -f /run/current-system
nix eval --raw .#deployTargets.raider
```

Expected: identical paths.

- [ ] **Step 3: Confirm the scheduler survived Task 1's change**

```bash
systemctl is-active scx-loader.service
```

Expected: `active`. raider is on unstable, so it still takes the `scx-loader` branch — this checks that the `optionalAttrs` restructuring did not silently drop the definition.

- [ ] **Step 4: Deploy one remote host**

```bash
nix develop -c just deploy galactica
```

Expected: phase 2 uses `--target-host root@galactica.bat-boa.ts.net --use-substitutes`. Watch for `substituting` / `copying path` lines showing galactica fetching from attic rather than receiving the whole closure from the local machine.

- [ ] **Step 5: Deploy the full tier, exercising the aarch64 path**

```bash
nix develop -c just deploy @tier1
```

Expected: all three hosts activate in parallel with interleaved `[host]` prefixes. basestar builds through itself as the aarch64 remote builder configured in `nix-builders.conf`.

- [ ] **Step 6: Confirm no host was left behind**

```bash
for h in galactica basestar raider; do
  echo -n "$h: "
  if [ "$h" = "$(hostname)" ]; then readlink -f /run/current-system
  else ssh "root@$h.bat-boa.ts.net" readlink -f /run/current-system; fi
done
for h in galactica basestar raider; do
  echo "$h expected: $(nix eval --raw ".#deployTargets.$h")"
done
```

Expected: each host's `/run/current-system` matches its expected closure.

- [ ] **Step 7: Confirm the closures reached attic**

```bash
for h in galactica basestar raider; do
  p=$(nix eval --raw ".#deployTargets.$h")
  hash=$(basename "$p" | cut -d- -f1)
  echo -n "$h: "
  curl -sfI "https://attic.arsfeld.dev/system/${hash}.narinfo" >/dev/null \
    && echo "in cache" || echo "MISSING"
done
```

Expected: three `in cache` lines. If any is `MISSING`, `--attic-cache system` did not push and `weekly-deploy` will fail at `max-jobs = 0`.

- [ ] **Step 8: Check for failed units across the tier**

```bash
for h in galactica basestar raider; do
  echo "=== $h ==="
  if [ "$h" = "$(hostname)" ]; then systemctl --failed --no-legend
  else ssh "root@$h.bat-boa.ts.net" systemctl --failed --no-legend; fi
done
```

Expected: no output under any host.

- [ ] **Step 9: Push and watch CI**

```bash
git push origin master
gh run watch
```

Expected: `build.yml` green for all hosts — including blackbird, which Task 1 fixed and which has never been built with commit `931bef2` in place.

- [ ] **Step 10: Confirm weekly-deploy's assumptions still hold**

```bash
nix eval --raw .#nixosConfigurations.galactica.config.system.build.toplevel.drvPath
nix eval --raw .#deployTargets.galactica.drvPath
```

Expected: identical. `weekly-deploy` deploys `.#nixosConfigurations` with `max-jobs = 0`; if these ever diverge, Sunday's run fails rather than builds.

---

## Rollback

Every task is one commit. If the new pipeline misbehaves after Task 4, `just nr-deploy <host>` (plain `nixos-rebuild --flake`, one host at a time) still works and is untouched by this plan. Reverting Task 5's commit restores colmena, though it will still carry the derivation divergence that motivated the change.
