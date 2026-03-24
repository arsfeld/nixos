---
title: "refactor: Migrate all secrets from ragenix to sops-nix"
type: refactor
status: active
date: 2026-03-20
origin: docs/brainstorms/2026-03-20-migrate-secrets-to-sops-brainstorm.md
---

# Migrate All Secrets from Ragenix to sops-nix

## Overview

Consolidate all NixOS secret management from the current dual system (58 ragenix `.age` files + 9 sops-nix secrets) to sops-nix exclusively. The migration proceeds host-by-host — storage first, then cloud — with ragenix removed only after all hosts are migrated.

## Problem Statement

The repository maintains two parallel secret management systems:
- **Ragenix**: 58 individual `.age` files, each encrypted to specific host SSH keys, declared via `age.secrets.*`
- **sops-nix**: 9 secrets across 3 YAML files, declared via `sops.secrets.*`

This dual system creates cognitive overhead: different CLI workflows, different declaration patterns, different file formats. New secrets are already going to sops, but the majority remain on ragenix.

## Proposed Solution

Host-by-host migration converting every `age.secrets.*` declaration to `sops.secrets.*`, adding decrypted values to per-host sops YAML files. Constellation modules that declare secrets internally use conditional logic during the transition period.

### Key Design Decisions (see brainstorm: docs/brainstorms/2026-03-20-migrate-secrets-to-sops-brainstorm.md)

1. **Active hosts first**: Storage (30+ secrets) → Cloud (14 secrets) → remaining hosts later
2. **One YAML per host**: `secrets/sops/<hostname>.yaml` + `common.yaml` for shared secrets
3. **Host-by-host, secret-by-secret**: Each host is a deployable unit
4. **Ragenix removed after all hosts done**: Keep infrastructure during transition
5. **Constellation modules: conditional during transition** (revised from brainstorm — direct switch breaks hosts not yet migrated, see "Critical Constraint" below)

## Technical Approach

### Critical Constraint: email.nix is default=true

The `modules/constellation/email.nix` module declares `age.secrets.smtp_password` and is **enabled by default on every host**. Switching it directly to `sops.secrets` would break all unmigrated hosts simultaneously. The same applies to `modules/media/config.nix` (cloudflare) and `modules/constellation/backup.nix` (restic-password).

**Solution**: Add conditional logic to these modules during transition:

```nix
# In constellation modules that declare secrets:
config = lib.mkMerge [
  (lib.mkIf (cfg.enable && config.constellation.sops.enable) {
    sops.secrets.smtp_password = {
      mode = "0444";
      sopsFile = config.constellation.sops.commonSopsFile;
    };
  })
  (lib.mkIf (cfg.enable && !config.constellation.sops.enable) {
    age.secrets.smtp_password = {
      file = "${self}/secrets/smtp_password.age";
      mode = "444";
    };
  })
];
```

This enables gradual per-host migration. Remove the `age.secrets` branch and conditional after all hosts are on sops (Phase 4).

### Architecture

```
Current state:
  secrets/
    *.age (58 files, one per secret)
    secrets.nix (ragenix key declarations)
    sops/
      storage.yaml (3 secrets)
      cloud.yaml (3 secrets)
      common.yaml (3 secrets)

Target state (after Phase 2):
  secrets/
    *.age (kept until Phase 4 cleanup)
    secrets.nix (kept until Phase 4 cleanup)
    sops/
      storage.yaml (~35 secrets)
      cloud.yaml (~17 secrets)
      common.yaml (~6 secrets: tailscale-key, restic-password, smtp_password, cloudflare, etc.)
```

### Implementation Phases

#### Phase 1: Storage Host Migration

**Goal**: Migrate all storage-specific `age.secrets` to `sops.secrets`. Deploy and verify.

**Estimated secrets to migrate**: ~25 host-level + 6 module-level = ~31 total

##### Step 1.1: Prepare shared infrastructure

Update constellation modules with conditional sops/age logic:

| File | Secret(s) | Change |
|------|-----------|--------|
| `modules/constellation/email.nix:60-61` | `smtp_password` | Add conditional: sops if enabled, age fallback |
| `modules/constellation/backup.nix:75` | `restic-password` | Add conditional: sops if enabled, age fallback |
| `modules/media/config.nix:140-147` | `cloudflare` | Add conditional: sops if enabled, age fallback (preserve conditional owner=acme) |
| `modules/services/media-apps.nix:16-80` | `ohdio-env`, `qui-oidc-env`, `mydia-env` | Add conditional: sops if enabled, age fallback |

**Success criteria**: Build passes for ALL hosts (`nix build .#nixosConfigurations.<host>.config.system.build.toplevel`). No behavior change yet.

##### Step 1.2: Decrypt and add storage secrets to sops YAML

For each `.age` file used by storage:
1. Decrypt: `nix develop -c ragenix --rules secrets/secrets.nix -e <secret>.age`
2. Add key/value to `secrets/sops/storage.yaml` (or `common.yaml` for shared secrets)
3. Re-encrypt: `nix develop -c sops secrets/sops/storage.yaml`

**Storage-specific secrets** (→ `storage.yaml`):

| Secret | Current file | Declared in | Custom attrs |
|--------|-------------|-------------|--------------|
| `airvpn-env` | `airvpn-env.age` | `hosts/storage/configuration.nix:63` | — |
| `tailscale-exit-key` | `tailscale-exit-key.age` | `hosts/storage/configuration.nix:67` | — |
| `tailscale-env` | `tailscale-env.age` | `hosts/storage/services/misc.nix:24` | — |
| `romm-env` | `romm-env.age` | `hosts/storage/services/misc.nix:25` | — |
| `dex-clients-tailscale-secret` | `dex-clients-tailscale-secret.age` | `hosts/storage/services/auth.nix:130` | — |
| `dex-clients-qui-secret` | `dex-clients-qui-secret.age` | `hosts/storage/services/auth.nix:131` | — |
| `lldap-env` | `lldap-env.age` | `hosts/storage/services/auth.nix:132-133` | mode=444 |
| `lldap-password` | `lldap-password.age` | `hosts/storage/services/auth.nix:134-135` | mode=444 |
| `authelia-secrets` | `authelia-secrets.age` | `hosts/storage/services/auth.nix:136-137` | mode=444 |
| `restic-password` | `restic-password.age` | `hosts/storage/backup/backup-restic.nix:6` | — |
| `hetzner-storagebox-ssh-key` | `hetzner-storagebox-ssh-key.age` | `hosts/storage/backup/backup-restic.nix:7-11` | mode=0400, path=/root/.ssh/hetzner_storagebox |
| `hetzner-webdav-env` | `hetzner-webdav-env.age` | `hosts/storage/backup/backup-restic.nix:12-15` | mode=0400 |
| `homepage-env` | `homepage-env.age` | `hosts/storage/services/homepage.nix:233` | — |
| `forgejo-oidc-secret` | `forgejo-oidc-secret.age` | `hosts/storage/services/develop.nix:20-24` | owner=forgejo, mode=400 |
| `finance-tracker-env` | `finance-tracker-env.age` | `hosts/storage/services/home.nix:21-23` | mode=0400 |
| `transmission-openvpn-pia` | `transmission-openvpn-pia.age` | `hosts/storage/services/media.nix:75` | — |
| `qbittorrent-pia` | `qbittorrent-pia.age` | `hosts/storage/services/media.nix:76` | — |
| `airvpn-wireguard` | `airvpn-wireguard.age` | `hosts/storage/services/media.nix:77` + `qbittorrent-vpn.nix:21-24` | mode=400 (in qbittorrent-vpn) |
| `transmission-openvpn-airvpn` | `transmission-openvpn-airvpn.age` | `hosts/storage/services/media.nix:78` | — |

**Shared secrets** (→ `common.yaml`, add storage + cloud + raider keys):

| Secret | Current file | Used by hosts |
|--------|-------------|---------------|
| `tailscale-key` | `tailscale-key.age` | storage, cloud, raider, raspi3, octopi, r2s |
| `restic-password` | `restic-password.age` | storage, cloud, micro (via modules) |
| `smtp_password` | `smtp_password.age` | ALL hosts (email.nix default=true) |
| `cloudflare` | `cloudflare.age` | storage, cloud, raider (media.config) |

##### Step 1.3: Update storage Nix declarations

Convert each `age.secrets.*` to `sops.secrets.*` in storage's config files:

```nix
# Before:
age.secrets.authelia-secrets = {
  file = "${self}/secrets/authelia-secrets.age";
  mode = "444";
};
someService.secretFile = config.age.secrets.authelia-secrets.path;

# After:
sops.secrets.authelia-secrets = {
  mode = "0444";
};
someService.secretFile = config.sops.secrets.authelia-secrets.path;
```

**Files to modify on storage:**

| File | Secrets to convert | Notes |
|------|-------------------|-------|
| `hosts/storage/configuration.nix` | `airvpn-env`, `tailscale-exit-key` | |
| `hosts/storage/services/auth.nix` | 5 secrets | Complex: dex, lldap, authelia |
| `hosts/storage/services/misc.nix` | `tailscale-key`, `tailscale-env`, `romm-env` | tailscale-key → sopsFile = commonSopsFile |
| `hosts/storage/services/media.nix` | 4 secrets | `airvpn-wireguard` duplicated |
| `hosts/storage/services/qbittorrent-vpn.nix` | `airvpn-wireguard` | Must match media.nix declaration |
| `hosts/storage/services/homepage.nix` | `homepage-env` | |
| `hosts/storage/services/develop.nix` | `forgejo-oidc-secret` | owner=forgejo |
| `hosts/storage/services/home.nix` | `finance-tracker-env` | |
| `hosts/storage/backup/backup-restic.nix` | 3 secrets | `hetzner-storagebox-ssh-key` has custom path |

**Attribute mapping** (ragenix → sops-nix):

| ragenix | sops-nix | Notes |
|---------|----------|-------|
| `age.secrets.<name>.file` | (not needed — key name in YAML) | sops uses `sopsFile` to point to YAML |
| `age.secrets.<name>.mode` | `sops.secrets.<name>.mode` | Same semantics |
| `age.secrets.<name>.owner` | `sops.secrets.<name>.owner` | Same semantics |
| `age.secrets.<name>.group` | `sops.secrets.<name>.group` | Same semantics |
| `age.secrets.<name>.path` | `sops.secrets.<name>.path` | Same semantics |
| `config.age.secrets.<name>.path` | `config.sops.secrets.<name>.path` | Update all references |

For secrets from `common.yaml`, add `sopsFile = config.constellation.sops.commonSopsFile;`.

##### Step 1.4: Build and deploy storage

```bash
nix build .#nixosConfigurations.storage.config.system.build.toplevel
just deploy storage
```

##### Step 1.5: Verify storage services

Check every service that consumes a migrated secret:
- [ ] Authelia login works
- [ ] LLDAP responds
- [ ] Dex OIDC flows work
- [ ] Tailscale services respond
- [ ] Restic backups run
- [ ] Hetzner storagebox SSH key at correct path
- [ ] Homepage loads with env vars
- [ ] Forgejo OIDC login works
- [ ] Finance tracker starts
- [ ] Media services (transmission, qbittorrent) connect to VPN
- [ ] Romm starts
- [ ] Ohdio, Qui, Mydia containers start
- [ ] ACME certificates renew (cloudflare DNS)
- [ ] Email sending works (smtp_password)

---

#### Phase 2: Cloud Host Migration

**Goal**: Migrate all cloud-specific `age.secrets` to `sops.secrets`. Deploy and verify.

**Estimated secrets to migrate**: ~10 host-level (module secrets already handled by Phase 1 conditionals)

##### Step 2.1: Add cloud secrets to sops YAML

**Cloud-specific secrets** (→ `cloud.yaml`):

| Secret | Current file | Declared in | Custom attrs |
|--------|-------------|-------------|--------------|
| `tailscale-env` | `tailscale-env.age` | `hosts/cloud/services.nix:12` | — |
| `restic-rest-cloud` | `restic-rest-cloud.age` | `hosts/cloud/backup.nix:9-10` | mode=0400 |
| `plausible-secret-key` | `plausible-secret-key.age` | `hosts/cloud/services/plausible.nix:60-63` | mode=0440 |
| `plausible-smtp-password` | `plausible-smtp-password.age` | `hosts/cloud/services/plausible.nix:65-68` | mode=0440 |
| `github-runner-token` | `github-runner-token.age` | `hosts/cloud/services/development.nix:9` | — (unused/commented) |
| `forgejo-runner-token` | `forgejo-runner-token.age` | `hosts/cloud/services/development.nix:10` | — |
| `planka-db-password` | `planka-db-password.age` | `hosts/cloud/services/planka.nix:159-164` | owner=postgres, group=postgres, mode=0400 |
| `planka-secret-key` | `planka-secret-key.age` | `hosts/cloud/services/planka.nix:165-169` | mode=0400 |

**Cloud's shared secrets** already in `common.yaml` from Phase 1: `tailscale-key`, `restic-password`, `smtp_password`, `cloudflare`.

**Already on sops** (no change needed): `siyuan-auth-code` (but remove the age fallback in `siyuan.nix`)

##### Step 2.2: Update cloud Nix declarations

| File | Secrets to convert |
|------|-------------------|
| `hosts/cloud/services.nix` | `tailscale-key` (→ commonSopsFile), `tailscale-env` |
| `hosts/cloud/backup.nix` | `restic-password` (→ commonSopsFile), `restic-rest-cloud` |
| `hosts/cloud/services/plausible.nix` | `plausible-secret-key`, `plausible-smtp-password` |
| `hosts/cloud/services/development.nix` | `github-runner-token`, `forgejo-runner-token` |
| `hosts/cloud/services/planka.nix` | `planka-db-password`, `planka-secret-key` |
| `hosts/cloud/services/siyuan.nix` | Remove age fallback conditional (lines 122-128) |

##### Step 2.3: Build, deploy, verify cloud

```bash
nix build .#nixosConfigurations.cloud.config.system.build.toplevel
just deploy cloud
```

Verify:
- [ ] Plausible analytics loads
- [ ] Planka board accessible
- [ ] Siyuan syncs
- [ ] Forgejo runner connects
- [ ] Restic backup to cloud succeeds
- [ ] Tailscale services respond
- [ ] ACME certificates renew
- [ ] Email sending works

---

#### Phase 3: Remaining Hosts (Future)

**Goal**: Migrate raider, cottage, micro, and edge devices to sops.

For each host:
1. Get SSH host key: `ssh-keyscan -t ed25519 <host>.bat-boa.ts.net`
2. Convert to age: `ssh-to-age < <host_key>`
3. Add to `.sops.yaml` with a new creation rule for `secrets/sops/<host>.yaml`
4. Create `secrets/sops/<host>.yaml` with the host's secrets
5. Enable `constellation.sops.enable = true` in host config
6. Convert `age.secrets.*` → `sops.secrets.*`
7. Deploy and verify

**Per-host inventory:**

| Host | Secrets | Complexity |
|------|---------|-----------|
| raider | 4 direct + 2 module | Medium — has hardcoded `/run/agenix/` paths (fix first!) |
| cottage | 2 (garage) | Low |
| micro | 2 (restic) | Low |
| raspi3 | 1 (tailscale) | Low |
| octopi | 1 (tailscale) | Low |
| r2s | 1 (tailscale) | Low |
| router | 1 via email module | Low — email module conditional handles it |
| g14, core, hpe, striker | 0 direct, email module only | Trivial |

**Raider-specific fix**: Update hardcoded paths at `hosts/raider/configuration.nix:124-125`:
```nix
# Before:
jwtSecretKeyFile = "/run/agenix/stash-jwt-secret";
# After:
jwtSecretKeyFile = config.sops.secrets.stash-jwt-secret.path;
```

---

#### Phase 4: Cleanup

**Goal**: Remove ragenix entirely. Only execute after ALL hosts are on sops.

1. **Remove conditional logic** from constellation modules (email.nix, backup.nix, media/config.nix, media-apps.nix) — keep only the `sops.secrets` branch
2. **Delete all `.age` files** from `secrets/` (including orphaned `minio-credentials.age`)
3. **Delete `secrets/secrets.nix`** (ragenix rules file)
4. **Remove ragenix from flake inputs** in `flake.nix`
5. **Remove `inputs.ragenix.nixosModules.default`** from `baseModules` in `flake-modules/lib.nix:29`
6. **Remove the `ragenix` package** from dev shell if present in `flake-modules/dev.nix`
7. **Update CLAUDE.md** to remove ragenix documentation
8. **Delete unused secrets** that were never migrated:
   - `minio-credentials.age` (orphaned)
   - `ntfy-env.age`, `keycloak-pass.age`, `stash-password.age` (never consumed)
   - `ghost-session-secret.age`, `ghost-smtp-env.age`, `ghost-session-env.age` (legacy)
   - `borg-passkey.age`, `gluetun-pia.age`, `rclone-idrive.age`, `restic-truenas.age`, `idrive-env.age` (legacy)
   - `restic-rest-auth.age`, `restic-cottage-minio.age`, `openarchiver-env.age`, `mediamanager-env.age` (legacy)
   - `attic-credentials.age`, `attic-server-token.age`, `bitmagnet-env.age` (legacy)

## System-Wide Impact

### Interaction Graph

- Constellation modules (`email.nix`, `backup.nix`, `media/config.nix`) inject secrets into host configurations → all hosts inheriting these modules are affected
- `email.nix` is `default=true` → every host gets `smtp_password` secret → Phase 1 conditional logic is load-bearing until Phase 4
- Gateway (`modules/media/gateway.nix`) consumes `cloudflare` secret for ACME → certificate renewal depends on correct secret path
- Restic backup services reference `restic-password.path` → both module-level and host-level declarations exist → must migrate atomically per host

### Error Propagation

- sops-nix decryption failure → secret file not created at `/run/secrets/<name>` → service fails to start → systemd reports unit failure
- Missing key in `.sops.yaml` → `sops` CLI refuses to encrypt/decrypt → build-time error (good — fails fast)
- Wrong permissions → service can't read secret → runtime error in service logs

### State Lifecycle Risks

- **Mixed state is safe**: ragenix uses `/run/agenix/`, sops-nix uses `/run/secrets/` — no path collisions
- **Rollback safe**: Previous NixOS generations still reference `age.secrets` paths, and ragenix remains in `baseModules` throughout transition
- **Partial migration safe**: A host can have some secrets on sops and others on ragenix simultaneously (already proven on storage/cloud)

### API Surface Parity

All interfaces that declare secrets:
- `age.secrets.*` declarations in host configs (26 files)
- `age.secrets.*` declarations in constellation modules (4 files)
- `sops.secrets.*` declarations in host configs (4 files currently, expanding)
- `config.age.secrets.*.path` references in service configs (must all become `config.sops.secrets.*.path`)

## Acceptance Criteria

### Functional Requirements

- [ ] All storage services start and function with sops-managed secrets (Phase 1)
- [ ] All cloud services start and function with sops-managed secrets (Phase 2)
- [ ] `nix build` succeeds for every host configuration (no evaluation errors)
- [ ] Secret permissions (owner/group/mode) match pre-migration state
- [ ] `hetzner-storagebox-ssh-key` is at `/root/.ssh/hetzner_storagebox` after migration
- [ ] Shared secrets (`tailscale-key`, `smtp_password`, etc.) work on all hosts that consume them
- [ ] Raider's Stash service uses `config.sops.secrets.*.path` instead of hardcoded paths (Phase 3)

### Non-Functional Requirements

- [ ] Zero downtime during migration (deploy-and-verify, not stop-and-migrate)
- [ ] Rollback to previous generation works at every step
- [ ] No `.age` files remain after Phase 4 cleanup

### Quality Gates

- [ ] Each phase is a separate commit (or set of commits) that builds and deploys successfully
- [ ] Unused/orphaned secrets identified and not migrated (cleaned up in Phase 4)
- [ ] CLAUDE.md updated to reflect sops-only workflow after Phase 4

## Dependencies & Prerequisites

- `sops` CLI available in dev shell (already present)
- `ssh-to-age` tool for converting host SSH keys (needed for Phase 3)
- Access to decrypt existing `.age` files (user's SSH key)
- SSH access to all target hosts for deployment and verification
- All target hosts must have `/etc/ssh/ssh_host_ed25519_key` (sops-nix uses this for decryption)

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Service fails due to wrong secret permissions | Medium | High | Compare permissions before/after for every secret |
| email.nix conditional breaks a host | Low | High | Build ALL host configs after Step 1.1 |
| Duplicate `restic-password` causes conflict | Medium | Medium | Migrate both module-level and host-level atomically |
| Hardcoded `/run/agenix/` paths missed | Low | Medium | Grep for `/run/agenix` before each host migration |
| sops YAML grows unwieldy | Low | Low | One file per host keeps it manageable |

## Future Considerations

- After Phase 4, consider moving secrets to external secret stores (Vault, 1Password) with sops as the bridge
- sops supports multiple key types (age, PGP, cloud KMS) — age-only is fine for this repo
- The conditional module pattern from Phase 1 could become a `lib.mkSopsOrAgeSecret` helper if reused elsewhere

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-20-migrate-secrets-to-sops-brainstorm.md](docs/brainstorms/2026-03-20-migrate-secrets-to-sops-brainstorm.md) — Key decisions: active hosts first, one YAML per host, host-by-host migration, remove ragenix after all hosts done

### Internal References

- Sops module: `modules/constellation/sops.nix`
- Sops creation rules: `.sops.yaml`
- Ragenix declarations: `secrets/secrets.nix`
- Base modules loading: `flake-modules/lib.nix:28-34`
- Dual-mode pattern (template): `hosts/cloud/services/siyuan.nix:122-128`
- Hardcoded ragenix paths: `hosts/raider/configuration.nix:124-125`
- Custom secret path: `hosts/storage/backup/backup-restic.nix:10`
- email.nix (global blocker): `modules/constellation/email.nix:60-61`
- Conditional sops pattern: `modules/constellation/opencloud.nix:104`

### External References

- [sops-nix documentation](https://github.com/Mic92/sops-nix)
- [ragenix documentation](https://github.com/yaxitech/ragenix)
