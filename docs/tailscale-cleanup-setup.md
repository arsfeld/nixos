# Tailscale Ephemeral Node Cleanup

## Overview

A standalone script to clean up stale ephemeral Tailscale nodes. Since all tsnsrv nodes are ephemeral, we can safely delete any that haven't been seen recently. This prevents DNS conflicts and connection timeouts.

## Script Location

`scripts/cleanup-tailscale-nodes.sh`

## How It Works

1. **API-Based Deletion**: Uses the Tailscale API to identify and delete stale ephemeral nodes
2. **Tag-Based Filtering**: Only removes nodes with the specified tag (default: `tag:service`)
3. **Age-Based Filtering**: Only removes nodes that haven't been seen for more than the configured time (default: 5 minutes)
4. **Dry Run Support**: Can preview what would be deleted without making changes

## Usage

### Basic Usage

```bash
# Clean up stale nodes (requires API key at /run/agenix/tailscale-api-key)
./scripts/cleanup-tailscale-nodes.sh
```

### Dry Run

Preview what would be deleted without actually deleting:

```bash
./scripts/cleanup-tailscale-nodes.sh --dry-run
```

### Custom API Key Location

```bash
# Use a custom API key file
./scripts/cleanup-tailscale-nodes.sh --api-key /path/to/api-key

# Or set in a file in this repo (not committed)
echo "tskey-api-xxxxx" > .tailscale-api-key
./scripts/cleanup-tailscale-nodes.sh --api-key .tailscale-api-key
```

### Custom Settings

```bash
./scripts/cleanup-tailscale-nodes.sh \
  --tailnet your-tailnet.ts.net \
  --tag tag:service \
  --max-age 600
```

### All Options

```bash
./scripts/cleanup-tailscale-nodes.sh --help
```

Options:
- `--api-key FILE` - Path to file containing Tailscale API key (default: /run/agenix/tailscale-api-key)
- `--tailnet NAME` - Tailscale tailnet name (default: bat-boa.ts.net)
- `--tag TAG` - Node tag to filter by (default: tag:service)
- `--max-age SECONDS` - Maximum age in seconds before deletion (default: 300)
- `--dry-run` - Show what would be deleted without actually deleting
- `--help` - Show help message

## Setup

### 1. Generate a Tailscale API Key

1. Go to the [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)
2. Navigate to **Settings** → **Keys** → **API access tokens**
3. Click **Generate access token**
4. Give it a descriptive name (e.g., "Ephemeral Node Cleanup")
5. Select the following permissions:
   - **Devices**: Read and Write (required to list and delete devices)
6. Set an appropriate expiration (or choose "No expiration")
7. Copy the generated token (it starts with `tskey-api-`)

### 2. Store the API Key

#### Option A: In a local file (for development/testing)

```bash
# Create a local file (not committed to git)
echo "tskey-api-xxxxx" > .tailscale-api-key
chmod 600 .tailscale-api-key

# Run with the local key
./scripts/cleanup-tailscale-nodes.sh --api-key .tailscale-api-key
```

The `.gitignore` already includes `.tailscale-api-key` so it won't be committed.

#### Option B: As an encrypted secret (for production use on hosts)

```bash
# Enter the nix develop shell
nix develop

# Create the encrypted secret
echo "tskey-api-xxxxx" | ragenix -e secrets/tailscale-api-key.age --editor -

# Add to secrets.nix (if not already there)
# "tailscale-api-key.age".publicKeys = users ++ systems;
```

Note: You'll need to add the secret definition to `secrets/secrets.nix` if using this approach.

### 3. Run the Script

```bash
# First do a dry run to see what would be deleted
./scripts/cleanup-tailscale-nodes.sh --dry-run

# If the results look correct, run for real
./scripts/cleanup-tailscale-nodes.sh
```

## Example Output

```
Starting Tailscale ephemeral node cleanup...
Tailnet: bat-boa.ts.net
Node tag: tag:service
Max age: 300 seconds
Dry run: false

Fetching devices from Tailscale API...
Analyzing nodes...

Stale node: jellyfin-old
  ID: 12345
  Last seen: 2025-10-15T19:00:00Z
  Age: 2h 15m
  Deleting...
  ✓ Successfully deleted

Stale node: immich-stale
  ID: 67890
  Last seen: 2025-10-15T18:45:00Z
  Age: 2h 30m
  Deleting...
  ✓ Successfully deleted

==========================================
Cleanup complete
Successfully deleted 2 stale ephemeral nodes
```

## When to Run

Run this script manually when:
- You notice DNS conflicts or connection timeouts to services
- After restarting tsnsrv services multiple times
- You see many stale nodes in your Tailscale admin console
- As part of maintenance after making infrastructure changes

## Troubleshooting

### API Key Not Found

If you see "Error: Tailscale API key not found":
- Verify the file exists: `ls -la /run/agenix/tailscale-api-key` (or your custom path)
- Use `--api-key` to specify the correct path
- Ensure the file is readable by your user

### API Request Failures

If cleanup fails with "Failed to fetch devices from Tailscale API":
- Verify the API key is valid and not expired in the Tailscale admin console
- Check that the API key has the correct permissions (Devices: Read and Write)
- Ensure you have network connectivity to api.tailscale.com

### No Nodes Being Deleted

If the cleanup runs but doesn't delete any nodes:
- Run with `--dry-run` to see if any nodes match the criteria
- Check that the `--tag` matches the tag used by your tsnsrv services
- Verify the `--max-age` value isn't too high (nodes might not be old enough yet)
- List devices manually:
  ```bash
  curl -s -H "Authorization: Bearer $(cat .tailscale-api-key)" \
    "https://api.tailscale.com/api/v2/tailnet/bat-boa.ts.net/devices" | jq '.devices[] | {name, tags, isEphemeral, lastSeen}'
  ```

### Dependencies Not Found

If you see "command not found" errors:
- The script requires `curl` and `jq` to be installed
- On NixOS, run from `nix develop` shell which has these tools
- Or install them: `nix-shell -p curl jq`

## Security Considerations

- The API key has full read/write access to devices in your Tailnet
- Store the API key securely (use encrypted secrets or restricted file permissions)
- The script only deletes:
  - Ephemeral nodes (not permanent nodes)
  - Nodes with the specified tag
  - Nodes that haven't been seen for more than `--max-age` seconds
- Always do a dry run first when testing with new settings

## Related Documentation

- [Tailscale API Documentation](https://tailscale.com/kb/1101/api/)
- [tsnsrv Documentation](https://github.com/arsfeld/tsnsrv)
- [Ephemeral Nodes in Tailscale](https://tailscale.com/kb/1111/ephemeral-nodes/)
