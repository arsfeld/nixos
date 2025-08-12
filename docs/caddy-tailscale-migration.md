# Caddy Tailscale Migration Guide

## Overview
This guide documents the migration from 57 individual tsnsrv processes to a single Caddy instance with Tailscale OAuth integration, providing ~85% reduction in resource usage.

## Implementation Status

### Completed
- ✅ Created Caddy package with chrishoage's OAuth-supporting Tailscale plugin fork
- ✅ Created constellation module for Caddy Tailscale gateway (`modules/constellation/caddy-tailscale.nix`)
- ✅ Prepared service configurations for migration (`hosts/storage/services/caddy-tailscale.nix`)
- ✅ Created minimal test configuration (`hosts/storage/services/caddy-tailscale-test.nix`)
- ✅ Updated secrets configuration to include `tailscale-env.age`

### Next Steps

## 1. Create the Tailscale Environment Secret

The OAuth key needs to be in environment variable format for Caddy:

```bash
# Extract the current OAuth key from tailscale-key.age
cd /home/arosenfeld/Projects/nixos/secrets
ragenix -d tailscale-key.age --rules secrets.nix

# Create the environment file with the key
echo "TS_AUTHKEY=<your-oauth-key>" > tailscale-env.plain

# Encrypt it
ragenix -e tailscale-env.age --rules secrets.nix < tailscale-env.plain

# Clean up
rm tailscale-env.plain
```

## 2. Test with Minimal Services

Start with the test configuration to verify everything works:

```bash
# Edit storage configuration to use the test config
# In hosts/storage/services/default.nix, change:
# ./caddy-tailscale.nix -> ./caddy-tailscale-test.nix

# Build and test locally first
nix build ".#nixosConfigurations.storage.config.system.build.toplevel"

# Deploy to storage
just deploy storage

# Verify the test services work
curl https://speedtest.bat-boa.ts.net
curl https://homepage.bat-boa.ts.net
curl https://syncthing.bat-boa.ts.net
```

## 3. Monitor Resource Usage

Compare before and after resource usage:

```bash
# Before migration (with tsnsrv)
ssh storage 'ps aux | grep tsnsrv | wc -l'  # Should show ~57 processes
ssh storage 'ps aux | grep tsnsrv | awk "{sum+=\$6} END {print sum/1024\" MB\"}"'  # Memory usage

# After migration (with Caddy)
ssh storage 'ps aux | grep caddy'  # Should show 1 process
ssh storage 'systemctl status caddy'  # Check Caddy status
```

## 4. Gradual Service Migration

Once test services work, migrate services in groups:

### Phase 1: Internal Services (No Funnel)
- autobrr, bazarr, sonarr, radarr, prowlarr
- These don't need external access, lowest risk

### Phase 2: Mixed Services (Funnel + Conditional Auth)
- jellyfin, immich, filebrowser, nextcloud
- Test both internal and external access with auth

### Phase 3: Public Services (Funnel + Own Auth)
- gitea, grafana, home-assistant, plex
- These have their own authentication

## 5. Full Migration

Once confident, switch to the full configuration:

```bash
# In hosts/storage/services/default.nix, use:
./caddy-tailscale.nix  # Full config instead of test

# Deploy
just deploy storage

# Verify all services
for service in jellyfin immich plex gitea grafana; do
  echo "Testing $service..."
  curl -I https://$service.bat-boa.ts.net
done
```

## 6. Cleanup

After successful migration:

```bash
# Remove old tsnsrv configuration
# In hosts/storage/services/misc.nix, remove:
# - services.tsnsrv block
# - Individual tsnsrv service definitions

# Clean up test files
rm hosts/storage/services/caddy-tailscale-test.nix

# Update module imports as needed
```

## Troubleshooting

### Caddy won't start
- Check OAuth key: `systemctl status caddy`
- Verify secret: `sudo cat /run/agenix/tailscale-env`
- Check Caddy config: `caddy validate --config /etc/caddy/Caddyfile`

### Services not accessible
- Check Tailscale status: `tailscale status`
- Verify service is in Tailscale: `tailscale serve status`
- Check Caddy is binding: `ss -tlnp | grep caddy`

### Authentication issues
- Verify Authelia is accessible: `curl https://cloud.bat-boa.ts.net:63836/api/verify`
- Check auth bypass for Tailnet: Test from within Tailnet
- Review Caddy logs: `journalctl -u caddy -f`

### High resource usage
- Check Caddy metrics: `curl http://localhost:2019/metrics`
- Review active connections: `ss -tn | grep ESTABLISHED | wc -l`
- Monitor Caddy: `htop -p $(pgrep caddy)`

## Performance Expectations

### Before (57 tsnsrv processes)
- CPU: ~40% baseline
- RAM: ~2.4GB
- Processes: 57 separate Tailscale connections

### After (Single Caddy)
- CPU: ~5-10%
- RAM: ~200-300MB
- Processes: 1 Tailscale connection

### Expected Savings
- **85% reduction in proxy overhead**
- **56 fewer processes**
- **~2.1GB RAM saved**
- **30-35% CPU reduction**

## Rollback Plan

If issues occur, rollback is simple:

```bash
# Re-enable tsnsrv
# In hosts/storage/services/misc.nix, uncomment:
services.tsnsrv.enable = true;

# Disable Caddy Tailscale
# In hosts/storage/services/default.nix, comment out:
# ./caddy-tailscale.nix

# Deploy
just deploy storage
```

## Architecture Benefits

### Current (tsnsrv)
```
Internet → Tailscale Funnel → tsnsrv (per service) → Local Service
Tailnet  → tsnsrv (per service) → Local Service
```

### New (Caddy)
```
Internet → Tailscale Funnel → Caddy (single) → Local Services
Tailnet  → Caddy → Local Services
```

### Advantages
1. **Single process** instead of 57
2. **OAuth authentication** without key rotation
3. **Flexible routing** with Caddy's full capabilities
4. **Per-service auth rules** (none/external/always)
5. **Native Tailscale integration** via tsnet
6. **Centralized configuration** in one module
7. **Better observability** via Caddy admin API

## Additional Features

The new Caddy setup enables additional features:

- **Advanced routing rules** using Caddy matchers
- **Request/response manipulation** with headers
- **Rate limiting** per service
- **Custom error pages** per service
- **WebSocket support** with proper proxying
- **HTTP/3 support** when available
- **Metrics and monitoring** via Prometheus