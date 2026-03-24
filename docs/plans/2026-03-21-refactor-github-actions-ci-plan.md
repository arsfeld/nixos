---
title: Refactor GitHub Actions CI
type: refactor
status: completed
date: 2026-03-21
---

# Refactor GitHub Actions CI

## Overview

Replace the current 5 failing GitHub Actions workflows with 3 focused, reliable workflows. CI serves as a **build caching mechanism** — it builds NixOS closures and pushes them to the self-hosted Attic binary cache so local `just deploy <host>` pulls pre-built artifacts instead of rebuilding from scratch.

## Problem Statement

Current CI has a **~15% overall pass rate** across 30 recent runs:

| Workflow | Pass Rate | Root Cause |
|----------|-----------|------------|
| Build | 0/8 | `storage` always fails: deploy-rs Nix store path errors + SSH/Tailscale dependency |
| Weekly Update | 0/3 | Cascades from Build failures |
| Format | 7/7 | Works, but auto-commits are unwanted (noisy, can race) |
| Gitleaks | 6/10 | False positives on Nix store hashes and age-encrypted files |
| Docs | 0/1 | Missing `awesome-pages` mkdocs plugin |

The fundamental issue: **Build uses deploy-rs to SSH into machines and deploy**, but CI should only build and cache — deployment is done locally via `just deploy`.

## Proposed Solution

### 3 Workflows

**1. Build & Cache** (`build.yml`) — push to master, manual dispatch, callable by other workflows
- Build 3 hosts: `cloud` (aarch64), `storage` (x86_64), `raider` (x86_64)
- `nix build .#nixosConfigurations.<host>.config.system.build.toplevel` — no SSH, no deploy-rs, no Tailscale
- Push closures to Attic (`https://attic.arsfeld.dev/system`)
- Keep `magic-nix-cache` for intermediate build caching within GitHub Actions

**2. Weekly Update** (`update.yml`) — weekly cron (Sunday midnight UTC), manual dispatch
- `nix flake update` → build all 3 hosts via workflow_call → commit `flake.lock` if all pass

**3. Format Check** (`format.yml`) — push to master
- `alejandra --check .` — **fail-only**, no auto-commit
- User runs `just fmt` locally before pushing

**Dropped:** Gitleaks (false positives), Docs (broken, not maintained)

## Technical Considerations

### Removing deploy-rs and Tailscale from CI

The current Build workflow establishes a Tailscale connection, SSHes into target machines, and runs `deploy --skip-checks` (deploy-rs). This is the primary source of failures — the storage build consistently hits `error: path '/nix/store/...-linux-modules-shrunk/lib' is not in the Nix store`.

By switching to `nix build` only, we:
- Eliminate SSH/Tailscale as a dependency (no more `TS_OAUTH_CLIENT_ID`/`TS_OAUTH_SECRET` secrets needed)
- Eliminate deploy-rs (documented as broken with Nix 2.32+)
- Avoid Nix store corruption from remote deployment
- Reduce build complexity and failure surface

### Attic Integration

The Attic cache is already configured as a substituter on all hosts (`modules/constellation/common.nix:50-54`):
- **Endpoint**: `https://attic.arsfeld.dev/system`
- **Cache name**: `system`
- **Public key**: `system:mUX40QMM+dqZ0wQaHp7sH50UgiZnSXsInzc9/MvaZRc=`

The CI pattern mirrors `just cache <host>` from the justfile:
```bash
nix build '.#nixosConfigurations.<host>.config.system.build.toplevel' -o result-<host>
attic push system ./result-<host>
```

`attic-client` is available in the dev shell (`flake-modules/dev.nix:45`).

### Disk Space on GitHub Runners

NixOS closures (especially `storage` with kernel modules + media services) are large. The existing disk cleanup step is necessary and should be kept. GitHub runners have ~14GB free by default, ~45GB after cleanup.

### QEMU for aarch64

`cloud` is aarch64-linux. The current QEMU-based approach works (cloud builds pass). Future optimization: GitHub now offers ARM runners (`ubuntu-24.04-arm`) which would be faster, but QEMU is good enough for now.

### GitHub Secret: ATTIC_TOKEN

New secret required. The Attic JWT token from the local system (`~/.local/share/attic/config.toml`) needs to be added as a GitHub Actions secret.

Secrets cleanup:
- **Add**: `ATTIC_TOKEN`
- **Can remove** (no longer used): `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`

## Acceptance Criteria

- [x] `build.yml`: Builds `cloud`, `storage`, `raider` closures and pushes to Attic on every push to master
- [x] `build.yml`: Supports `workflow_call` with optional `flake_lock` input (for Weekly Update)
- [x] `build.yml`: Uses matrix strategy with `fail-fast: false`
- [x] `build.yml`: No SSH, no Tailscale, no deploy-rs — only `nix build` + `attic push`
- [x] `update.yml`: Runs weekly, updates `flake.lock`, builds all hosts, commits if all pass
- [x] `format.yml`: Fails if `alejandra --check .` finds unformatted files, does not auto-commit
- [x] `ATTIC_TOKEN` GitHub secret is set
- [x] Remove `gitleaks.yml` and `docs.yml`
- [x] Update CLAUDE.md CI/CD section to reflect new workflows

## MVP

### `.github/workflows/build.yml`

```yaml
name: "Build & Cache"

on:
  push:
    branches: [master]
  workflow_dispatch:
  workflow_call:
    inputs:
      flake_lock:
        description: "Base64-encoded flake.lock content"
        required: false
        type: string

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - host: cloud
            platform: aarch64-linux
          - host: storage
            platform: x86_64-linux
          - host: raider
            platform: x86_64-linux

    name: ${{ matrix.host }}
    runs-on: ubuntu-latest
    timeout-minutes: 120
    permissions:
      contents: read

    steps:
      - name: Free disk space
        run: |
          sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL
          sudo apt-get clean
          docker image prune --all --force

      - uses: actions/checkout@v4

      - name: Setup QEMU for aarch64
        if: matrix.platform == 'aarch64-linux'
        uses: docker/setup-qemu-action@v3

      - uses: cachix/install-nix-action@v31
        with:
          extra_nix_config: extra-platforms = aarch64-linux i686-linux

      - uses: DeterminateSystems/magic-nix-cache-action@main

      - name: Override flake.lock
        if: inputs.flake_lock
        run: echo '${{ inputs.flake_lock }}' | base64 -d > flake.lock

      - name: Build and push to cache
        shell: nix develop --command bash -e {0}
        env:
          ATTIC_TOKEN: ${{ secrets.ATTIC_TOKEN }}
        run: |
          set -euo pipefail

          echo "Building ${{ matrix.host }}..."
          nix build '.#nixosConfigurations.${{ matrix.host }}.config.system.build.toplevel' \
            -o "result-${{ matrix.host }}"

          echo "Pushing to Attic cache..."
          attic login system https://attic.arsfeld.dev "$ATTIC_TOKEN"
          attic push system "./result-${{ matrix.host }}"

          echo "Done: ${{ matrix.host }} built and cached"
```

### `.github/workflows/update.yml`

```yaml
name: "Weekly Update"

on:
  schedule:
    - cron: "0 0 * * 0"
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  update:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
    outputs:
      has_changes: ${{ steps.check.outputs.has_changes }}
      flake_lock: ${{ steps.check.outputs.flake_lock }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: cachix/install-nix-action@v31
      - name: Update flake inputs
        id: check
        run: |
          set -euo pipefail
          nix flake update
          if git diff --quiet; then
            echo "has_changes=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          echo "has_changes=true" >> "$GITHUB_OUTPUT"
          echo "flake_lock=$(base64 -w0 flake.lock)" >> "$GITHUB_OUTPUT"

  build:
    needs: update
    if: needs.update.outputs.has_changes == 'true'
    uses: ./.github/workflows/build.yml
    permissions:
      contents: read
    with:
      flake_lock: ${{ needs.update.outputs.flake_lock }}
    secrets: inherit

  commit:
    needs: [update, build]
    if: needs.update.outputs.has_changes == 'true' && success()
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Commit updated flake.lock
        run: |
          set -euo pipefail
          echo "${{ needs.update.outputs.flake_lock }}" | base64 -d > flake.lock
          git config user.name 'github-actions[bot]'
          git config user.email 'github-actions[bot]@users.noreply.github.com'
          git add flake.lock
          git commit -m "chore: update flake inputs"
          git push
```

### `.github/workflows/format.yml`

```yaml
name: "Format Check"

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v31
      - name: Check formatting
        run: nix run nixpkgs#alejandra -- --check .
```

## Implementation Steps

1. Add `ATTIC_TOKEN` as a GitHub Actions secret
2. Replace `build.yml` with the new Build & Cache workflow
3. Replace `update.yml` with the simplified Weekly Update workflow
4. Replace `format.yml` with the check-only Format Check workflow
5. Delete `gitleaks.yml` and `docs.yml`
6. Update CLAUDE.md CI/CD section
7. Push and verify all 3 workflows pass

## Sources

- Attic config: `modules/constellation/common.nix:50-54`
- Cache recipe pattern: `justfile:156-167`
- Dev shell with attic-client: `flake-modules/dev.nix:45`
- Current failing workflows: `.github/workflows/`
