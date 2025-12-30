---
id: task-160.4
title: Set up Tailscale auth key secret for project VMs
status: To Do
assignee:
  - '@arosenfeld'
created_date: '2025-12-28 20:55'
updated_date: '2025-12-28 21:05'
labels:
  - feature
  - infrastructure
dependencies: []
parent_task_id: task-160
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add Tailscale auth key for project VMs to sops secrets. The key enables VMs to automatically join the tailnet with proper tagging.

## Tailscale Key Requirements
- **Reusable**: Yes (multiple VMs use same key)
- **Pre-authorized**: Yes (no manual approval needed)
- **Ephemeral**: No (VMs persist)
- **Tags**: `tag:project-vm`

## ACL Configuration
Ensure Tailscale ACL includes:
```json
{
  "tagOwners": {
    "tag:project-vm": ["autogroup:admin"]
  }
}
```

## Secret Location
Add to `secrets/sops/common.yaml`:
```yaml
tailscale-project-vm-key: tskey-auth-xxxxx
```

## Key Generation
Via Tailscale API or admin console at https://login.tailscale.com/admin/settings/keys
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Tailscale auth key added to secrets/sops/common.yaml
- [ ] #2 Key is reusable and pre-authorized
- [ ] #3 ACL updated with tag:project-vm permissions
- [ ] #4 Key tested and verified working
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## User Action Required

This task requires manual steps that cannot be automated:

### Step 1: Update Tailscale ACLs

Add to your Tailscale ACL configuration at https://login.tailscale.com/admin/acls:

```json
{
  "tagOwners": {
    "tag:project-vm": ["autogroup:admin"]
  }
}
```

### Step 2: Generate Auth Key

Via Tailscale Admin Console:
1. Go to https://login.tailscale.com/admin/settings/keys
2. Click "Generate auth key"
3. Configure:
   - Reusable: Yes
   - Ephemeral: No
   - Pre-authorized: Yes
   - Tags: tag:project-vm
   - Expiry: 90 days (or as needed)
4. Copy the key (starts with `tskey-auth-`)

Or via API:
```bash
curl -X POST -u "YOUR_API_KEY:" \
  -H "Content-Type: application/json" \
  -d '{
    "capabilities": {
      "devices": {
        "create": {
          "reusable": true,
          "ephemeral": false,
          "preauthorized": true,
          "tags": ["tag:project-vm"]
        }
      }
    },
    "expirySeconds": 7776000,
    "description": "Project VM auth key"
  }' \
  "https://api.tailscale.com/api/v2/tailnet/-/keys"
```

### Step 3: Create Common Secrets File

```bash
# Create the common.yaml file with the tailscale key
cat > /tmp/common-plain.yaml << 'EOF'
tailscale-project-vm-key: tskey-auth-YOUR_KEY_HERE
EOF

# Encrypt with sops
nix develop -c sops --encrypt /tmp/common-plain.yaml > secrets/sops/common.yaml

# Clean up
rm /tmp/common-plain.yaml
```

### Step 4: Verify

```bash
nix develop -c sops --decrypt secrets/sops/common.yaml
```

### Module Configuration Reference

Once the secret is created, reference it in host configuration:

```nix
sops.secrets.tailscale-project-vm-key = {
  sopsFile = config.constellation.sops.commonSopsFile;
  mode = "0400";
};

constellation.projectVms = {
  enable = true;
  tailscaleAuthKeyFile = config.sops.secrets.tailscale-project-vm-key.path;
  sshPublicKey = "ssh-ed25519 AAAA...";
};
```
<!-- SECTION:NOTES:END -->
