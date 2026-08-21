# Replacing colmena with nix-fast-build + `nixos-rebuild --store-path` (design)

**Date:** 2026-08-20
**Scope:** `flake-modules/`, `justfile`, `just/`, `modules/constellation/gaming.nix`, `flake.nix`, docs
**Status:** Design approved, not implemented.

## Problem

`just deploy` is the last thing in this repo that evaluates the fleet through a second,
cache-incompatible path. It is currently broken outright, and the two reasons are
unrelated to each other.

### The immediate break: blackbird cannot evaluate

Commit `931bef2` (`feat(modules): adopt bpftune, LACT, scx-loader and cgroup gaming
boost`, unpushed as of this writing) added to `modules/constellation/gaming.nix`:

```nix
scx-loader = lib.mkIf (cfg.scheduler != "none") {
  enable = true;
  config.default_sched = "scx_${cfg.scheduler}";
};
```

`services.scx-loader` exists only in nixpkgs-unstable — `nixos/modules/module-list.nix`
line 1513 lists `./services/scheduling/scx-loader.nix` in unstable and has no counterpart
in 26.05. `unstableHosts` is `["raider"]`, but **blackbird** also sets
`constellation.gaming.enable = true` (`hosts/blackbird/configuration.nix:31`) and is on
stable. So:

```
$ nix eval --raw .#nixosConfigurations.blackbird.config.system.build.toplevel.drvPath
error: The option `services.scx-loader' does not exist.
```

`lib.mkIf false` would not have saved it: unknown-option checking runs on the *definition
path*, before the condition is evaluated. Of the four things `931bef2` adopted, only
`scx-loader` is unstable-only — `bpftune`, `lact`, `ananicy` and `earlyoom` are all in
both channels. CI has not gone red yet only because the commit is not pushed.

### Why that one broken host takes down every deploy

`flake-modules/colmena.nix:66-73` computes the aarch64 node list like this:

```nix
aarch64Hosts = builtins.filter (name: let
    hostConfig = self.nixosConfigurations.${name}.config;
    ...
  ) self.hosts;
```

That force-evaluates **every** `self.nixosConfigurations` entry just to build
`nodeNixpkgs`. One broken host therefore fails the whole hive, so `just deploy raider`
dies on blackbird's error even though blackbird is not a target:

```
… while evaluating the option `nodeNixpkgs':
error: The option `services.scx-loader' does not exist.
```

Note that the popular diagnosis — "colmena substitutes its own nixpkgs, so raider gets
stable modules" — is **not** what happens. Colmena 0.4's `src/nix/hive/eval.nix:117-122`
does `evalConfig = import (npkgs.path + "/nixos/lib/eval-config.nix")` per node, so
`meta.nodeNixpkgs.raider = import inputs.nixpkgs-unstable {…}` correctly gives raider
unstable's *module set* as well as its packages. Mixed channels are not colmena's problem.

### The structural problem: two evaluations, one cache

Colmena's `meta.nixpkgs` must be an already-instantiated nixpkgs. `import inputs.nixpkgs
{…}` drops the flake's revision metadata, so the hive produces `…-26.05pre-git`
derivations where `.#nixosConfigurations` produces dated ones. Different derivation paths
mean nothing colmena builds is ever in attic, and nothing CI caches is ever usable by
colmena.

This already forced `weekly-deploy` off colmena and onto `nixos-rebuild --flake
.#nixosConfigurations` with `max-jobs = 0` (documented at length in CLAUDE.md). `just
deploy` is the last holdout.

### The requirement colmena was satisfying

Parallel evaluation. A plain `nixos-rebuild` evaluates one host at a time, and the fleet's
tier-1 set is three hosts. Any replacement has to keep that, plus keep building locally
and pushing results to attic — which is what the `attic watch-store system` background
process in every current `just` recipe is for.

## Goals

1. One evaluation path — `.#nixosConfigurations` — shared by `just deploy`, the CI matrix,
   and `weekly-deploy`, so all three realise byte-identical derivations.
2. Parallel evaluation across the named hosts.
3. Build locally, push to attic, and let each target substitute its own closure.
4. A failure in any host's build blocks activation on all of them.
5. Keep `switch` / `boot` / `test` / `reboot`, tier selection, and self-deployment.

## Non-goals

- `deployment.keys`. Nothing in the repo uses it; sops-nix covers secrets.
- Magic rollback / auto-rollback. Not enabled today (`flake-modules/deploy.nix` sets both
  to `false`).
- Changing how `weekly-deploy` deploys. It already uses `nixos-rebuild` against
  `.#nixosConfigurations` and stays as-is.

## Approach

Two phases, split at a barrier.

**Phase 1 — parallel eval, build, and attic push** via
[`nix-fast-build`](https://github.com/Mic92/nix-fast-build) (1.6.0, in nixpkgs). It drives
`nix-eval-jobs` with one worker per attribute, so the hosts evaluate concurrently, then
builds and pushes to attic natively via `--attic-cache`.

**Phase 2 — parallel activation** via `nixos-rebuild --store-path`. This flag activates a
pre-built system closure with no evaluation and no build, works with `--target-host` and
`--use-substitutes`, and supports `switch`, `boot`, `test` and `dry-activate`. It means
zero hand-rolled activation logic: no manual `nix-env -p /nix/var/nix/profiles/system
--set`, no bare `switch-to-configuration` call.

### Alternatives considered

| Option | Why not |
|---|---|
| N parallel `nixos-rebuild --flake` processes | Simplest possible thing, and gets parallel eval free from process separation. Rejected for the missing barrier: each host activates the instant its own build finishes, so a change that breaks host 3 leaves hosts 1–2 already switched. Also cannot make targets substitute their own closures from attic. |
| Re-adopt deploy-rs | Its Nix 2.32 bug ([#340](https://github.com/serokell/deploy-rs/issues/340)) is closed as of 2025-11-05 and the repo is active (last commit 2026-08-10), and it consumes `nixosConfigurations` directly so it is cache-correct. But it deploys nodes sequentially — it does not solve the problem this work exists for. |
| Keep colmena, only fix `aarch64Hosts` | Stops one broken host from killing the hive, but leaves the derivation divergence untouched. The cache would still never hit. |

## Design

### Section 0 — Unblock blackbird

`modules/constellation/gaming.nix` takes `options` as a module argument and selects
whichever scheduler module the host's channel actually has. Stable's
`services.scx` (`nixos/modules/services/scheduling/scx.nix`) exposes `{ enable, scheduler,
package, extraArgs }` with `scheduler` defaulting to `"scx_rustland"`, which maps cleanly.

```nix
services =
  {
    ratbagd.enable = true;
    # … unchanged entries …
  }
  # scx-loader landed in nixpkgs after 26.05. Hosts still on stable fall back to
  # services.scx: same daemon, same scheduler, minus the org.scx.Loader D-Bus
  # interface for switching schedulers at runtime.
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

The rejected alternative — adding `blackbird` to `unstableHosts` — is one line, but moves
an entire laptop to unstable as a side effect of one scheduler option.

### Section 1 — `flake.deployTargets`

`flake-modules/deploy.nix` is rewritten; its deploy-rs contents are deleted.

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

### Section 2 — The driver (`just/deploy.just`)

A private `_apply ACTION +TARGETS` recipe backs `deploy` (switch), `boot`, `test` and
`dry-run` (dry-activate). `reboot` chains off `boot`.

```bash
_apply ACTION +TARGETS:
    #!/usr/bin/env bash
    set -euo pipefail

    # @tier1 expands to that tier's hosts; bare names pass through. Dedupe.
    hosts=$(for t in {{ TARGETS }}; do
      case "$t" in
        @*) nix eval --json ".#tiers.${t#@}" | jq -r '.[]' ;;
        *)  echo "$t" ;;
      esac
    done | sort -u)

    out=$(mktemp -d); trap 'rm -rf "$out"' EXIT

    # Phase 1 — parallel eval (one nix-eval-jobs worker per attr), parallel
    # build, attic push. Two flags are load-bearing:
    #   --systems must name both. The default is the local system only, and
    #     nix-fast-build silently drops attrs for any other one (workers.py:74),
    #     which would skip basestar entirely.
    #   Do NOT add --skip-cached. It makes nix-eval-jobs skip already-cached
    #     attrs outright (workers.py:68), leaving no local store path for
    #     --store-path to hand to phase 2.
    nix-fast-build \
      --flake '.#deployTargets' \
      --select "t: { inherit (t) $hosts; }" \
      --systems "x86_64-linux aarch64-linux" \
      --attic-cache system \
      --out-link "$out/result"

    # Phase 2 — activate in parallel from the pre-built closures. No re-eval.
    #
    # Each host runs inside a subshell that re-raises PIPESTATUS[0]. Without
    # that, `cmd | sed &` makes $! the PID of *sed*, and `wait` would report
    # sed's exit status — masking every failed activation as a success.
    pids=()
    for h in $hosts; do
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
    rc=0; for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
    exit $rc
```

`nix-fast-build --out-link "$out/result"` writes one `result-<attr>` symlink per host
(`build.py:265`), which doubles as a GC root for the duration of phase 2 and makes path
discovery a `readlink` rather than a second evaluation.

Public recipes:

```
deploy     +TARGETS  -> _apply switch
boot       +TARGETS  -> _apply boot
test       +TARGETS  -> _apply test
dry-run    +TARGETS  -> _apply dry-activate
reboot     +TARGETS  -> _apply boot, then ssh root@<h>.bat-boa.ts.net systemctl reboot
deploy-all           -> _apply switch $(nix eval --json .#hosts | jq -r '.[]')
build      HOST      -> nix build .#deployTargets.<HOST>
cache      HOST      -> unchanged; retargeted to .#deployTargets.<HOST>
info                 -> nix eval --json .#hosts | jq -r '.[]'
```

`build` and `cache` keep their current behaviour — `.#deployTargets.<HOST>` and
`.#nixosConfigurations.<HOST>.config.system.build.toplevel` are the same derivation, and
the shorter path is what the rest of the driver already uses. `cache` stays useful as the
one-host "build and push, don't deploy" utility; `deploy` no longer needs it because
`--attic-cache` pushes inline.

Target syntax is `just deploy galactica raider`, `just deploy @tier1`, or a mix. The `@`
prefix keeps tiers and hostnames in separate namespaces. `just deploy` with no arguments
is an error, not an implicit `@tier1`.

Behaviour changes to record in the docs:

- `just reboot` becomes `boot` followed by an explicit `systemctl reboot` over SSH.
  `nixos-rebuild` has no `--reboot` flag.
- `just dry-run` becomes build-then-`dry-activate`. Colmena's `dry-run` skipped building;
  this one does not, but in exchange it reports the units that would actually restart.
- `attic watch-store system` disappears from every recipe. `--attic-cache system` pushes
  the result closures directly, so the background watcher, its PID bookkeeping, the
  `trap`, and the `sleep 1` all come out.

### Section 3 — Removals

- Delete `flake-modules/colmena.nix` and its import from `flake.nix`.
- Delete the `deploy-rs` flake input and the `deploy-rs`, `boot-rs`, `trace-rs` recipes.
- `flake-modules/dev.nix`: drop the `colmena` override and the deploy-rs package; add

  ```nix
  (nix-fast-build.override {
    nix-eval-jobs = inputs.det-nix-eval-jobs.packages.${system}.default;
  })
  ```

  This override is load-bearing for exactly the reason the colmena one was: nixpkgs ships
  nix-eval-jobs 2.35 while these machines run Determinate Nix 2.34.8.
- Keep the `det-nix-eval-jobs` input. It stops feeding colmena and starts feeding
  nix-fast-build.
- Keep `_poke-targets` unchanged.
- Rewrite CLAUDE.md's Deployment section. The standing warning "It deploys
  `nixosConfigurations`, deliberately, not the colmena hive" becomes obsolete once colmena
  is gone; replace it with the shorter invariant that every deploy path must evaluate
  `.#nixosConfigurations` and never `import inputs.nixpkgs`. Update the README host table's
  deployment column and the tier documentation, which currently cites `colmena apply --on
  @tier1`.
- `flake-modules/hosts.nix`: the `tiers` comment referencing colmena `deployment.tags`
  needs updating; `tiers` itself is unchanged and is now read by `just` via `nix eval`.

### Section 4 — Verification

1. `nix build .#nixosConfigurations.blackbird.config.system.build.toplevel` succeeds.
   Gates everything else.
2. `nix eval --raw .#deployTargets.raider.drvPath` equals
   `nix eval --raw .#nixosConfigurations.raider.config.system.build.toplevel.drvPath`.
   This is the single-evaluation-path claim, checked directly.
3. `just dry-run @tier1` completes and reports per-host unit changes.
4. `just deploy raider` — exercises the self-deployment branch.
5. `just deploy @tier1` — exercises `--target-host`, `--use-substitutes`, and the aarch64
   path through basestar as its own remote builder.
6. Confirm the barrier: point `_apply` at a deliberately broken host alongside a good one
   and check that neither activates.
7. Push and confirm CI is green **before** the Sunday `weekly-deploy` window.
   `weekly-deploy` runs with `max-jobs = 0` and can only deploy a commit CI has already
   built and pushed to attic.

## Risks

| Risk | Mitigation |
|---|---|
| nix-eval-jobs version skew against Determinate Nix | Override `nix-eval-jobs` with the `det-nix-eval-jobs` input, mirroring what the colmena override already did. Verified at step 3. |
| Three concurrent evaluations exhaust memory on the deploy host | `nix-fast-build --eval-workers` and `--eval-max-memory-size` bound it. Tier 1 is three hosts; raise only if step 5 shows pressure. |
| `--store-path` is newer surface than `--flake` and less exercised | Step 3 (`dry-activate`) and step 4 (single host) come before any multi-host switch. `nr-deploy`/`nr-boot`/`nr-test` stay in the justfile as the `--flake` fallback. |
| aarch64 closure downloads back to the deploy host | Unchanged from today — colmena also ran with `buildOnTarget = false`, and `builders-use-substitutes = true` is already set in `home/home.nix`. If it proves costly, `--build-host` on basestar is a follow-up, not part of this design. |

## Out of scope

Whether blackbird should move to nixpkgs-unstable alongside raider. Section 0 makes the
gaming module work on both channels; the channel choice is a separate decision.
