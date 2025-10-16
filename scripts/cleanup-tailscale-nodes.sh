#!/usr/bin/env bash
# Cleanup stale ephemeral Tailscale nodes
#
# This script uses the Tailscale API to delete stale ephemeral nodes.
# Since all tsnsrv nodes are ephemeral, we can safely delete any that
# haven't been seen recently.
#
# API Key:
#   The script looks for the API key in the following order:
#   1. TAILSCALE_API_KEY environment variable
#   2. TAILSCALE_API_KEY in .env file (repo root)
#   3. File specified with --api-key option
#
# Usage:
#   ./cleanup-tailscale-nodes.sh [OPTIONS]
#
# Options:
#   --api-key FILE      Path to file containing Tailscale API key
#   --tailnet NAME      Tailscale tailnet name (default: bat-boa.ts.net)
#   --tag TAG           Node tag to filter by (default: tag:service)
#   --max-age SECONDS   Maximum age in seconds before deletion (default: 300)
#   --ephemeral-only    Only delete ephemeral nodes (default: false, deletes all stale nodes)
#   --dry-run           Show what would be deleted without actually deleting
#   --help              Show this help message

set -euo pipefail

# Default values
API_KEY_FILE=""
TAILNET="bat-boa.ts.net"
TAG="tag:service"
MAX_AGE_SECONDS=300
EPHEMERAL_ONLY=false
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
    --max-age)
      MAX_AGE_SECONDS="$2"
      shift 2
      ;;
    --ephemeral-only)
      EPHEMERAL_ONLY=true
      shift
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

echo "Starting Tailscale node cleanup..."
echo "Tailnet: $TAILNET"
echo "Node tag: $TAG"
echo "Max age: $MAX_AGE_SECONDS seconds"
echo "Ephemeral only: $EPHEMERAL_ONLY"
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

# Parse and delete stale ephemeral nodes
CURRENT_TIME=$(date +%s)

echo "Analyzing nodes..."
echo ""

# Store results in temp file to avoid subshell issues
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

# Use jq to filter and process devices
STALE_NODES=$(jq -r --arg tag "$TAG" --arg current "$CURRENT_TIME" --arg max_age "$MAX_AGE_SECONDS" --argjson ephemeral_only "$EPHEMERAL_ONLY" '
  .devices[] |
  select(if $ephemeral_only then .isEphemeral == true else true end) |
  select(.tags != null and (.tags[] | contains($tag))) |
  select(.lastSeen != null) |
  select(
    (($current | tonumber) - (.lastSeen | fromdateiso8601)) > ($max_age | tonumber)
  ) |
  "\(.id)|\(.name)|\(.lastSeen)|" + (($current | tonumber) - (.lastSeen | fromdateiso8601) | tostring) + "|" + (if .isEphemeral then "ephemeral" else "permanent" end)
' <<< "$RESPONSE")

if [ -z "$STALE_NODES" ]; then
  echo "No stale nodes found"
  echo ""
  echo "=========================================="
  echo "Cleanup complete"
  echo "No stale nodes to delete"
  exit 0
fi

DELETED=0
TOTAL_ELIGIBLE=0

while IFS='|' read -r device_id device_name last_seen age_seconds node_type; do
  TOTAL_ELIGIBLE=$((TOTAL_ELIGIBLE + 1))

  # Convert age to human readable format
  age_minutes=$((age_seconds / 60))
  age_hours=$((age_minutes / 60))

  if [ $age_hours -gt 0 ]; then
    age_display="${age_hours}h $((age_minutes % 60))m"
  else
    age_display="${age_minutes}m"
  fi

  echo "Stale node: $device_name"
  echo "  ID: $device_id"
  echo "  Type: $node_type"
  echo "  Last seen: $last_seen"
  echo "  Age: $age_display"

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would delete this node"
  else
    echo "  Deleting..."

    DELETE_RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE \
      -H "Authorization: Bearer $API_KEY" \
      "https://api.tailscale.com/api/v2/device/$device_id")

    HTTP_CODE=$(echo "$DELETE_RESPONSE" | tail -n1)

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
      echo "  ✓ Successfully deleted"
      DELETED=$((DELETED + 1))
    else
      echo "  ✗ Failed to delete (HTTP $HTTP_CODE)" >&2
    fi
  fi

  echo ""
done <<< "$STALE_NODES"

echo "=========================================="
if [ "$DRY_RUN" = true ]; then
  echo "Cleanup complete (DRY RUN)"
  echo "Found $TOTAL_ELIGIBLE stale nodes that would be deleted"
else
  echo "Cleanup complete"
  echo "Successfully deleted $DELETED stale nodes"
fi
