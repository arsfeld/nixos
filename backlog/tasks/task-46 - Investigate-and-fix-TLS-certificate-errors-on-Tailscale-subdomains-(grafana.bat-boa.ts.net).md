---
id: task-46
title: >-
  Investigate and fix TLS certificate errors on Tailscale subdomains
  (grafana.bat-boa.ts.net)
status: To Do
assignee:
  - '@claude'
created_date: '2025-10-16 18:16'
updated_date: '2025-10-16 18:29'
labels:
  - bug
  - tls
  - caddy
  - tailscale
  - observability
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Problem

When accessing services via Caddy-Tailscale subdomains (e.g., https://grafana.bat-boa.ts.net/), TLS handshake fails with error:
```
curl: (35) TLS connect error: error:0A000438:SSL routines::tlsv1 alert internal error
```

## Current State

- Tailscale nodes are created successfully (grafana, jellyfin, plex, immich, etc.)
- HTTP redirects to HTTPS work correctly (308 redirect)
- Direct access via `http://storage.bat-boa.ts.net:3010/` works fine
- The TLS handshake fails during certificate validation

## Workaround

Users can access Grafana directly at: `http://storage.bat-boa.ts.net:3010/`

## Investigation Areas

1. **Caddy-Tailscale certificate provisioning**
   - Check if certificates are being requested/issued correctly
   - Review caddy logs for certificate errors
   - Verify Tailscale HTTPS configuration

2. **Tailscale OAuth credentials**
   - Verify TS_API_CLIENT_ID and TS_API_CLIENT_SECRET are set correctly
   - Check if OAuth tokens are being refreshed properly

3. **Multiple service conflict**
   - With 13+ services exposed via Tailscale, ensure no port/cert conflicts
   - Review if all services have the same TLS issue or just grafana

4. **Caddy configuration**
   - Review the generated Caddyfile for TLS directives
   - Check if `tls` block is correctly configured for Tailscale domains

## References

- Storage host: services exposed via caddy-tailscale
- Cloud host: also has caddy-tailscale but different services
- Router: isolated, doesn't use caddy-tailscale
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 TLS handshake succeeds for https://grafana.bat-boa.ts.net/
- [ ] #2 All Tailscale-exposed services accessible via HTTPS
- [ ] #3 No certificate errors in Caddy logs
- [ ] #4 Root cause identified and documented
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Investigation Summary

### Root Cause
The TLS handshake failure was caused by **missing Tailscale certificate manager configuration** in Caddy virtual hosts. When services are bound to Tailscale nodes using `bind tailscale/<service>`, Caddy needs to explicitly request certificates from Tailscale using the `get_certificate tailscale` directive.

### Technical Details
1. **Original Issue**: Virtual hosts were using ACME certificates for `*.arsfeld.one` domain while being bound to Tailscale nodes
2. **Certificate Mismatch**: ACME certs don't match `*.bat-boa.ts.net` hostnames, causing TLS handshake failures
3. **Plugin Requirement**: caddy-tailscale plugin requires explicit certificate manager configuration when site address doesn't include full `.ts.net` hostname

### Fix Implemented
Modified `modules/media/__utils.nix` to:
1. Remove ACME `useACMEHost` directive when binding to Tailscale
2. Add `tls { get_certificate tailscale }` directive for Tailscale-bound hosts
3. Only apply Tailscale TLS config when `exposeViaTailscale = true` and service runs on current host

### Configuration Changes
```nix
# Before:
"grafana.arsfeld.one" = {
  useACMEHost = "arsfeld.one";  # Wrong cert for *.bat-boa.ts.net
  extraConfig = ''bind tailscale/grafana'';
};

# After:
"grafana.arsfeld.one" = {
  # No useACMEHost directive
  extraConfig = ''
    bind tailscale/grafana
    tls { get_certificate tailscale }  # Use Tailscale certs
  '';
};
```

### Additional Requirement
**Tailscale HTTPS must be enabled** in the Tailscale admin console:
1. Go to DNS settings in Tailscale admin console
2. Enable HTTPS certificates
3. This allows Tailscale to provision certificates for `*.bat-boa.ts.net` domains

Reference: https://tailscale.com/kb/1153/enabling-https

## Update: Fix Incomplete

The implemented changes did not resolve the issue. Tailscale HTTPS is already enabled. The problem is that individual service nodes created by caddy-tailscale cannot provision certificates.

Created task-47 with proper investigation steps and possible solutions.

**Next Steps**: Close this task and work on task-47 instead.
<!-- SECTION:NOTES:END -->
