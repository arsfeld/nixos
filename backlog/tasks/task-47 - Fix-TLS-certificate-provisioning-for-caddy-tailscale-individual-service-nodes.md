---
id: task-47
title: Fix TLS certificate provisioning for caddy-tailscale individual service nodes
status: To Do
assignee: []
created_date: '2025-10-16 18:29'
updated_date: '2025-10-16 18:40'
labels:
  - bug
  - tls
  - caddy
  - tailscale
  - observability
  - blocked
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

Tailscale nodes created by caddy-tailscale plugin for individual services (grafana.bat-boa.ts.net, jellyfin.bat-boa.ts.net, etc.) cannot provision TLS certificates, causing handshake failures:

```
curl: (35) TLS connect error: error:0A000438:SSL routines::tlsv1 alert internal error
```

## Current State

- ✅ Tailscale HTTPS is enabled in admin console
- ✅ Caddy configuration includes `tls { get_certificate tailscale }` directive
- ✅ Individual Tailscale nodes are registered and active (grafana, jellyfin, etc.)
- ❌ TLS handshake still fails for all `*.bat-boa.ts.net` subdomains
- ❌ `tailscale cert grafana.bat-boa.ts.net` returns: "invalid domain; must be one of [storage.bat-boa.ts.net]"

## What Was Already Tried (Didn't Work)

1. Added `tls { get_certificate tailscale }` to Caddyfile for Tailscale-bound hosts
2. Removed ACME certificate directives
3. Verified Tailscale OAuth credentials are configured
4. Confirmed nodes are ephemeral and tagged correctly

## Root Cause Analysis Needed

The issue is that **individual service nodes cannot provision certificates**. Only the main `storage.bat-boa.ts.net` host can get certificates. This suggests:

1. The separate Tailscale nodes created by caddy-tailscale may not have HTTPS enabled
2. There may be a configuration issue with how ephemeral nodes request certificates
3. The OAuth client credentials may not have sufficient permissions
4. Tailscale may not support HTTPS for tagged/ephemeral nodes created via tsnet

## Investigation Steps

1. Check if Tailscale supports HTTPS for tsnet-created nodes
2. Review caddy-tailscale plugin GitHub issues for similar problems
3. Test if using the main storage Tailscale node (instead of individual nodes) works
4. Investigate if OAuth clients have necessary permissions for certificate provisioning
5. Check Tailscale admin console to see if individual nodes show HTTPS enabled

## Possible Solutions

1. **Use SNI routing on main node**: Instead of separate nodes per service, use one Tailscale node with SNI-based routing
2. **Request certs manually**: Pre-provision certificates for each service node using tailscale CLI
3. **Use Tailscale Serve**: Switch from caddy-tailscale to Tailscale's built-in `tailscale serve` feature
4. **Check permissions**: Ensure OAuth client has ACL permissions for certificate generation

## References

- caddy-tailscale plugin: https://github.com/tailscale/caddy-tailscale
- Tailscale HTTPS docs: https://tailscale.com/kb/1153/enabling-https
- Current config: modules/media/__utils.nix:96-116
- Current Caddyfile: /etc/caddy/caddy_config on storage host
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 TLS handshake succeeds for https://grafana.bat-boa.ts.net/
- [ ] #2 All Tailscale-exposed services (13+ services) accessible via HTTPS
- [ ] #3 Certificate provisioning works for individual service nodes
- [ ] #4 Root cause documented with working solution
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Results (2025-10-16)

### Current Status

Confirmed configuration:
- ✅ HTTPS enabled in Tailscale admin console
- ✅ MagicDNS enabled in Tailscale admin console (confirmed)
- ✅ OAuth credentials configured
- ✅ Caddy configuration with `tls { get_certificate tailscale }` directive
- ✅ Individual Tailscale nodes registered and active
- ❌ TLS handshake still fails with: `curl: (35) TLS connect error: error:0A000438:SSL routines::tlsv1 alert internal error`

### Why `tailscale cert grafana.bat-boa.ts.net` Fails

This is expected behavior! The `tailscale cert` command on the storage host can only get certificates for `storage.bat-boa.ts.net` because:
- The storage host's Tailscale daemon is a separate node named `storage`
- The grafana node is a DIFFERENT tsnet node created by Caddy
- Each tsnet node must provision its own certificate through tsnet's GetCertificate mechanism
- You cannot use `tailscale cert` on one node to get certificates for another node

### Next Investigation Steps

Since MagicDNS + HTTPS are both confirmed enabled, need to investigate:

1. Check Caddy logs on storage for certificate provisioning errors
2. Verify tsnet nodes are actually requesting certificates (may be failing silently)
3. Check if OAuth client has correct permissions for certificate provisioning
4. Verify the tsnet nodes can actually communicate with Tailscale control plane
5. Test if the issue is specific to ephemeral nodes or affects all tsnet nodes
6. Check if there's a rate limit or certificate request failure in Tailscale logs

### References

- tsnet HTTPS requirements: https://github.com/tailscale/tailscale/issues/12303
- caddy-tailscale plugin: https://github.com/tailscale/caddy-tailscale
- Tailscale HTTPS docs: https://tailscale.com/kb/1153/enabling-https
- Current config: modules/media/__utils.nix:96-116
<!-- SECTION:NOTES:END -->
