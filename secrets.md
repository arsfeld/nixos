# Secret Recovery Plan

## Issue Summary
On August 27, 2025, during a re-encryption operation with `agenix -r`, many secrets were corrupted and now decrypt to empty content. The problematic commit is `8586c69` from August 1, 2025.

## Root Cause
The `agenix -r` command appears to have failed silently, encrypting empty content instead of the actual secret values. This likely happened because:
1. The secrets were not properly decrypted before re-encryption
2. Missing keys in secrets.nix or incorrect key configuration
3. Possible race condition or environmental issue during the re-encryption process

## Affected Secrets

### Completely Empty (High Priority)
- authelia-secrets.age
- bitmagnet-env.age
- dex-clients-tailscale-secret.age
- finance-tracker-env.age
- ghost-session-env.age
- ghost-session-secret.age
- ghost-smtp-env.age
- lldap-env.age
- restic-cottage-minio.age

### Errors During Decryption (Missing from secrets.nix)
- keycloak-pass.age
- plausible-admin-password.age
- restic-rest-auth.age
- restic-rest-micro.age
- tailscale-env.age

### Partially Working (Lower Priority)
- ntfy-env.age (has content)
- plausible-secret-key.age (has content)
- plausible-smtp-password.age (has content)
- qbittorrent-pia.age (has content)
- restic-password.age (has content)
- restic-rest-cloud.age (has content)
- romm-env.age (has content)
- smtp_password.age (has content)
- tailscale-key.age (has content)
- transmission-openvpn-pia.age (partial content)

### Truncated (Need Verification)
- borg-passkey.age
- cloudflare.age
- github-runner-token.age
- gluetun-pia.age
- google-api-key.age
- homepage-env.age
- idrive-env.age
- minio-credentials.age
- rclone-idrive.age
- restic-truenas.age

## Recovery Steps

### Step 1: Backup Current State
```bash
cp -r secrets/ secrets.backup-$(date +%Y%m%d-%H%M%S)/
```

### Step 2: Restore from Git History
Restore each file from the commit before the corruption (commit `98b2157`):

```bash
# High priority - completely empty secrets
git checkout 98b2157 -- secrets/authelia-secrets.age
git checkout 98b2157 -- secrets/bitmagnet-env.age
git checkout 98b2157 -- secrets/dex-clients-tailscale-secret.age
git checkout 98b2157 -- secrets/finance-tracker-env.age
git checkout 98b2157 -- secrets/ghost-session-env.age
git checkout 98b2157 -- secrets/ghost-session-secret.age
git checkout 98b2157 -- secrets/ghost-smtp-env.age
git checkout 98b2157 -- secrets/lldap-env.age

# Files with decryption errors (check if they existed before)
git checkout 98b2157 -- secrets/keycloak-pass.age
git checkout 98b2157 -- secrets/plausible-admin-password.age
git checkout 98b2157 -- secrets/restic-rest-auth.age
git checkout 98b2157 -- secrets/restic-rest-micro.age
git checkout 98b2157 -- secrets/tailscale-env.age

# Truncated files that need restoration
git checkout 98b2157 -- secrets/borg-passkey.age
git checkout 98b2157 -- secrets/cloudflare.age
git checkout 98b2157 -- secrets/github-runner-token.age
git checkout 98b2157 -- secrets/gluetun-pia.age
git checkout 98b2157 -- secrets/google-api-key.age
git checkout 98b2157 -- secrets/homepage-env.age
git checkout 98b2157 -- secrets/idrive-env.age
git checkout 98b2157 -- secrets/minio-credentials.age
git checkout 98b2157 -- secrets/rclone-idrive.age
git checkout 98b2157 -- secrets/restic-truenas.age

# Note: restic-cottage-minio.age was created in 8586c69, needs manual recreation
```

### Step 3: Verify Restored Secrets
```bash
nix develop -c bash -c 'cd secrets && for file in *.age; do echo "=== $file ==="; agenix -d "$file" 2>&1 | wc -c; done'
```

### Step 4: Fix secrets.nix
Ensure all secrets are properly defined in secrets.nix with correct paths and keys.

### Step 5: Test Decryption
```bash
nix develop -c bash -c 'cd secrets && for file in *.age; do echo -n "$file: "; agenix -d "$file" >/dev/null 2>&1 && echo "OK" || echo "FAILED"; done'
```

## Prevention Measures

### Never Use `agenix -r` Without Verification
1. Always backup secrets before re-keying
2. Test decryption after any re-encryption
3. Use version control to track changes

### Improved Re-keying Process
```bash
# 1. Backup
cp -r secrets/ secrets.backup-$(date +%Y%m%d)/

# 2. Test current decryption
for file in secrets/*.age; do
  echo "Testing $file"
  agenix -d "$file" > /dev/null || echo "FAILED: $file"
done

# 3. Only proceed if all decrypt successfully
# 4. Run agenix -r
# 5. Immediately verify all secrets still decrypt properly
```

### Add CI Check
Create a GitHub Action that verifies all secrets can be decrypted (without exposing content).

### Document Secret Recreation
For each secret, document:
- Where to find/regenerate the value
- Which services depend on it
- Impact if missing

## Immediate Actions Required
1. **DO NOT run `agenix -r` again** until we understand why it's erasing secrets
2. Restore all secrets from git history
3. Verify each secret decrypts properly
4. Deploy critical services that are currently broken
5. Implement prevention measures

## Services Impact Assessment
Services likely affected by empty secrets:
- Authelia (authentication)
- Ghost blog
- LLDAP
- Bitmagnet
- Finance tracker
- All backup services (restic, borg)
- Tailscale networking