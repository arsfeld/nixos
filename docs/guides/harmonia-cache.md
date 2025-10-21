# Harmonia Binary Cache

This cache replaces the previous Attic deployment and serves as the primary binary cache for the fleet.

## Service Overview
- **Host**: `raider`
- **Port**: `5000`
- **Systemd unit**: `harmonia-dev.service`
- **Process**: `harmonia-cache` from `nix-community/harmonia`
- **State directory**: `/var/lib/harmonia`
- **Health check**: `harmonia-healthcheck.timer` probes `http://127.0.0.1:5000/nix-cache-info`
- **Frontends**:
  - `https://harmonia.arsfeld.one` via the cloud Caddy gateway
  - `https://harmonia.bat-boa.ts.net` via tsnsrv on `raider`

## Secrets
- Signing key: `secrets/harmonia-cache-key.age`
  - Decrypt/reference as `config.age.secrets."harmonia-cache-key"`
  - Regenerate with: `nix-store --generate-binary-cache-key harmonia-raider-1 <priv> <pub>`
  - Re-encrypt using `ragenix -e secrets/harmonia-cache-key.age --editor '-'`
- Tailscale auth: reuses `secrets/tailscale-key.age` (shared with other tsnsrv deployments)

## Client Configuration
Added globally in `modules/constellation/common.nix`:
- Substituters: `https://harmonia.arsfeld.one`, `https://harmonia.bat-boa.ts.net`
- Trusted key: `harmonia-raider-1:Cn74XNGOtXB2y3yHlU7uXoTpJqWA2p0l74Dcdwqt5aU=`

All hosts inherit these settings through `constellation.common`.

## Retention & Storage
- `keep-outputs`/`keep-derivations` enabled on `raider` to prevent garbage collection of recently built artifacts.
- `nix.gc.options = "--max-free 75G --min-free 25G"` keeps at least 25 GiB of space free while allowing the cache to grow aggressively.
- Harmonia's state directory is managed by systemd (`StateDirectory=harmonia`), so metadata survives reboots.
- Artifacts are pinned automatically during deployments (see `nix/var/nix/gcroots/tests` in tests and deployment workflows).

## Validation
1. Deploy `raider` (`just deploy raider`)
2. From another host (or dev shell):
   ```bash
   nix build '.#packages.x86_64-linux.hello' \
     --option substituters "https://harmonia.arsfeld.one https://cache.nixos.org" \
     --option trusted-public-keys "harmonia-raider-1:Cn74XNGOtXB2y3yHlU7uXoTpJqWA2p0l74Dcdwqt5aU= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
   ```
   The build should download from the Harmonia cache.
3. CI/Dev validation: `nix build .#checks.x86_64-linux.harmonia-cache-test -L` boots a Harmonia VM, serves a signed artifact, and ensures a second node can fetch it across restarts and garbage collection.

## Operations
- Restart service: `sudo systemctl restart harmonia-dev`
- View logs: `journalctl -u harmonia-dev -f`
- Health timer status: `systemctl status harmonia-healthcheck.timer`
- Rotate signing key:
  1. Generate new key with `nix-store --generate-binary-cache-key`
  2. Update `secrets/harmonia-cache-key.age`
  3. Redeploy affected hosts

## Notes
- Harmonia is configured with zstd compression and cache priority 60 so clients prefer it over `cache.nixos.org`.
- tsnsrv on `raider` publishes the Tailscale node; no additional firewall rules are required (host firewall disabled).
- The legacy Attic cache remains deployed; nothing pushes to it automatically now that builds prefer Harmonia.
