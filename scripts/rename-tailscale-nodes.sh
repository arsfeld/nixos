#!/usr/bin/env bash
# Rename Tailscale nodes with -1, -2, etc. suffixes to their proper names
#
# This script finds nodes like "service-1" and renames them to "service"
#
# API Key:
#   The script looks for the API key in the following order:
#   1. TAILSCALE_API_KEY environment variable
#   2. TAILSCALE_API_KEY in .env file (repo root)
#   3. File specified with --api-key option
#
# Usage:
#   ./rename-tailscale-nodes.sh [OPTIONS]
#
# Options:
#   --api-key FILE      Path to file containing Tailscale API key
#   --tailnet NAME      Tailscale tailnet name (default: bat-boa.ts.net)
#   --tag TAG           Node tag to filter by (default: tag:service)
#   --dry-run           Show what would be renamed without actually renaming
#   --help              Show this help message

set -euo pipefail

# Default values
API_KEY_FILE=""
TAILNET="bat-boa.ts.net"
TAG="tag:service"
DRY_RUN=false

# Check for .env file in repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
if [ -f "$REPO_ROOT/.env" ]; then
  source "$REPO_ROOT/.env"
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --api-key)
      API_KEY_FILE="$2"
      shift 2
      ;;
    --tailnet)
      TAILNET="$2"
      shift 2
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

# Get API key from environment variable or file
if [ -n "${TAILSCALE_API_KEY:-}" ]; then
  API_KEY="$TAILSCALE_API_KEY"
elif [ -n "$API_KEY_FILE" ]; then
  if [ ! -f "$API_KEY_FILE" ]; then
    echo "Error: Tailscale API key file not found at $API_KEY_FILE" >&2
    exit 1
  fi
  API_KEY=$(cat "$API_KEY_FILE")
else
  echo "Error: Tailscale API key not found" >&2
  echo "Either set TAILSCALE_API_KEY environment variable (or in .env file)" >&2
  echo "or use --api-key to specify a file path" >&2
  exit 1
fi

echo "Starting Tailscale node renaming..."
echo "Tailnet: $TAILNET"
echo "Node tag: $TAG"
echo "Dry run: $DRY_RUN"
echo ""

# Fetch all devices from Tailscale API
echo "Fetching devices from Tailscale API..."
RESPONSE=$(curl -s \
  -H "Authorization: Bearer $API_KEY" \
  "https://api.tailscale.com/api/v2/tailnet/$TAILNET/devices")

if [ $? -ne 0 ]; then
  echo "Error: Failed to fetch devices from Tailscale API" >&2
  exit 1
fi

echo "Analyzing nodes..."
echo ""

# Find nodes with -1, -2, etc. suffixes and extract their info
NODES_TO_RENAME=$(jq -r --arg tag "$TAG" '
  .devices[] |
  select(.tags != null and (.tags[] | contains($tag))) |
  select(.name | test("-[0-9]+\\.")) |
  "\(.id)|\(.name)|" + (.name | sub("-[0-9]+\\."; "."))
' <<< "$RESPONSE")

if [ -z "$NODES_TO_RENAME" ]; then
  echo "No nodes found with -1, -2, etc. suffixes"
  echo ""
  echo "=========================================="
  echo "Renaming complete"
  echo "No nodes need renaming"
  exit 0
fi

RENAMED=0
TOTAL=0

while IFS='|' read -r device_id current_name new_name; do
  TOTAL=$((TOTAL + 1))

  echo "Node: $current_name"
  echo "  ID: $device_id"
  echo "  New name: $new_name"

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would rename this node"
  else
    echo "  Renaming..."

    # Extract the short name (without domain)
    new_short_name=$(echo "$new_name" | sed 's/\.bat-boa\.ts\.net$//')

    RENAME_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"$new_short_name\"}" \
      "https://api.tailscale.com/api/v2/device/$device_id")

    HTTP_CODE=$(echo "$RENAME_RESPONSE" | tail -n1)

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
      echo "  ✓ Successfully renamed"
      RENAMED=$((RENAMED + 1))
    else
      echo "  ✗ Failed to rename (HTTP $HTTP_CODE)" >&2
      RESPONSE_BODY=$(echo "$RENAME_RESPONSE" | head -n -1)
      echo "  Error: $RESPONSE_BODY" >&2
    fi
  fi

  echo ""
done <<< "$NODES_TO_RENAME"

echo "=========================================="
if [ "$DRY_RUN" = true ]; then
  echo "Renaming complete (DRY RUN)"
  echo "Found $TOTAL nodes that would be renamed"
else
  echo "Renaming complete"
  echo "Successfully renamed $RENAMED nodes"
fi
