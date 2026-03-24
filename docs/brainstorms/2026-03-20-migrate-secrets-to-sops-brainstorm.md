# Brainstorm: Migrate All Secrets to sops-nix

**Date:** 2026-03-20
**Status:** Ready for planning

## What We're Building

A complete migration from ragenix to sops-nix for all secret management in this NixOS configuration. The goal is to consolidate on a single secrets system, eliminating the cognitive overhead of maintaining two parallel approaches.

### Current State
- **58 ragenix secrets** across 9+ hosts (individual `.age` files)
- **9 sops secrets** across 3 YAML files (storage, cloud, common)
- Only storage and cloud have `constellation.sops.enable = true`
- Both NixOS modules (ragenix + sops-nix) are loaded on all hosts via `baseModules`

### Target State
- All secrets managed via sops-nix
- One YAML file per host + `common.yaml` for shared secrets
- Ragenix fully removed (after all hosts migrated)

## Why This Approach

**Motivation:** Simplify to one system. Two parallel secret systems adds unnecessary complexity — different CLI workflows, different declaration patterns (`age.secrets.*` vs `sops.secrets.*`), different file formats.

**Why sops over ragenix:**
- Already adopted for newer secrets — momentum is toward sops
- YAML files group multiple secrets per host (vs one `.age` file per secret)
- sops-nix is more actively maintained in the NixOS ecosystem
- Editing secrets is simpler (`sops secrets/sops/storage.yaml` vs individual file operations)

## Key Decisions

1. **Scope: Active hosts first** — Start with storage and cloud (already hybrid), then migrate remaining hosts (raider, r2s, raspi3, etc.) in a follow-up effort.

2. **File layout: One YAML per host** — Keep the current pattern of `secrets/sops/<hostname>.yaml` + `common.yaml`. Simple, mirrors the existing sops module structure.

3. **Migration strategy: Host-by-host, secret-by-secret** — Fully migrate storage first (most secrets, ~30), deploy and verify, then cloud (~12 secrets). Each host is a deployable unit.

4. **Cleanup: Remove ragenix after all hosts done** — Keep ragenix infrastructure (flake input, `secrets/secrets.nix`, `.age` files) until every host is on sops. Then do a final cleanup pass removing ragenix entirely.

## Migration Steps (High-Level)

### Phase 1: Storage (priority — most secrets)
1. Ensure `.sops.yaml` has correct age keys for storage host
2. For each `age.secrets.*` in storage's config:
   - Decrypt the `.age` file value
   - Add the value to `secrets/sops/storage.yaml`
   - Change the Nix declaration from `age.secrets.*` to `sops.secrets.*`
   - Preserve owner/group/mode settings
3. Handle secrets declared in constellation modules (backup.nix, email.nix, media config)
4. Deploy to storage and verify all services start correctly

### Phase 2: Cloud
1. Add cloud host key to `.sops.yaml` if not already present
2. Same per-secret migration process as storage
3. Deploy to cloud and verify

### Phase 3: Remaining hosts (future)
1. Enable `constellation.sops.enable` on each host
2. Add host age keys to `.sops.yaml`
3. Migrate their (few) secrets
4. Deploy and verify

### Phase 4: Cleanup (after all hosts done)
1. Remove all `.age` files from `secrets/`
2. Delete `secrets/secrets.nix`
3. Remove ragenix flake input
4. Remove ragenix from `baseModules`
5. Remove any transitional fallback patterns (e.g., siyuan's `mkIf` pattern)

## Additional Decisions

5. **Constellation modules: Switch to sops directly** — Modules like backup.nix, email.nix, and media/config.nix that declare `age.secrets` internally will be updated to use `sops.secrets` directly. No conditional fallback. This means hosts using those modules must have sops enabled before deployment.

6. **Orphaned minio-credentials.age: Delete it** — Not referenced anywhere, safe to remove during cleanup.

## Things to Watch

- **Secret ownership/permissions:** ragenix and sops-nix handle `owner`/`group`/`mode` slightly differently. Verify each service's secret file has correct permissions after migration.
- **Constellation modules:** Some modules (backup.nix, email.nix, media/config.nix) declare `age.secrets` internally. These need updating to `sops.secrets` with appropriate conditionals or direct changes.
- **Common/shared secrets:** Secrets used by multiple hosts (tailscale-key, restic-password, cloudflare) need to go in `common.yaml` with correct key access rules.
- **Secret formats:** Some secrets are files (e.g., cloudflare credentials JSON), some are env files, some are plain strings. Sops handles all of these but the YAML encoding may differ.
- **Orphaned secret:** `minio-credentials.age` exists on disk but isn't declared in `secrets/secrets.nix` — can likely be deleted.
