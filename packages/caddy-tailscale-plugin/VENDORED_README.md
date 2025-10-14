# Vendored caddy-tailscale Plugin (OAuth Support)

This directory contains a vendored copy of the caddy-tailscale plugin with OAuth client credentials support.

## Source

- **Original Repository**: https://github.com/tailscale/caddy-tailscale
- **OAuth Fork**: https://github.com/erikologic/caddy-tailscale
- **Branch**: main (as of 2025-09-19)
- **License**: Apache 2.0 (see LICENSE file)
- **Related PR**: https://github.com/tailscale/caddy-tailscale/pull/109

## Why Vendored?

This plugin is vendored into our repository for the following reasons:

1. **OAuth Support**: The official caddy-tailscale plugin doesn't have OAuth client credentials support yet. PR #109 adds this feature but is not merged.

2. **Nix Build Requirements**: Nix builds require all sources to be available at build time without network access. Vendoring ensures reproducible builds.

3. **Stability**: By vendoring, we control when to update the plugin and can test changes before upgrading.

4. **Single OAuth Key**: The OAuth support enables using a single OAuth client key to register multiple Tailscale nodes, reducing our resource usage from 58 tsnsrv processes to a single Caddy instance (85% reduction).

## OAuth Features

The vendored version adds:

- OAuth client credentials authentication (`TS_API_CLIENT_ID` + `TS_AUTHKEY`)
- Multi-node support with single OAuth key
- Ephemeral node registration
- Node tagging support
- Runtime auth key generation from OAuth credentials

## Upstream Tracking

We should periodically check if PR #109 has been merged into the official repository:
- https://github.com/tailscale/caddy-tailscale/pull/109

Once merged and released, we can switch to using the official version and remove this vendored copy.

## Usage in Our Configuration

This plugin is built into Caddy via `packages/caddy-tailscale/default.nix` and used in:
- `modules/constellation/caddy-tailscale.nix` - Module configuration
- `hosts/storage/services/caddy-tailscale.nix` - Service declarations

## Attribution

Original work by the Tailscale team and contributors.
OAuth support implementation by [@erikologic](https://github.com/erikologic).

See LICENSE file for full license text.
