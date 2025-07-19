#!/usr/bin/env bash
# Local testing script for NAT-PMP server

set -e

echo "Building NAT-PMP server..."
nix build .#natpmp-server

echo "Creating test state directory..."
mkdir -p ./test-state

echo "Starting NAT-PMP server in test mode..."
echo "Note: This will fail on nftables commands without proper permissions"
echo "For full testing, run with sudo or in a NixOS VM"

./result/bin/natpmp-server \
  --listen-interface lo \
  --listen-port 15351 \
  --external-interface lo \
  --state-dir ./test-state \
  --log-level debug \
  "$@"