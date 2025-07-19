#!/usr/bin/env bash
# Script to clean up duplicate NAT-PMP mappings

echo "Cleaning up duplicate NAT-PMP mappings on router..."

ssh root@router.bat-boa.ts.net 'cat /var/lib/natpmp-server/mappings.json | jq ".mappings |= unique_by({internal_ip, internal_port, external_port, protocol})" > /var/lib/natpmp-server/mappings.json.cleaned && mv /var/lib/natpmp-server/mappings.json.cleaned /var/lib/natpmp-server/mappings.json'

echo "Restarting NAT-PMP server..."
ssh root@router.bat-boa.ts.net 'systemctl restart natpmp-server'

echo "Done! Checking new mapping count..."
ssh root@router.bat-boa.ts.net 'cat /var/lib/natpmp-server/mappings.json | jq ".mappings | length"'