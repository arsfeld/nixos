# Caddy with Tailscale Plugin

This package builds Caddy web server with the official Tailscale plugin, enabling OAuth authentication and secure networking features.

## Overview

This is a properly vendored build of Caddy that includes the [tailscale/caddy-tailscale](https://github.com/tailscale/caddy-tailscale) plugin. The plugin provides:

- **Tailscale OAuth Authentication**: Authenticate users via their Tailscale identity
- **Tailscale TLS Certificates**: Automatically provision TLS certificates via Tailscale
- **Tailscale Reverse Proxy Transport**: Connect to upstream services over Tailscale

## Build Approach

This package follows Nix best practices for building Go modules with local dependencies:

### Architecture

1. **Main Package** (`packages/caddy-tailscale/`):
   - Contains `main.go` that imports both Caddy and the Tailscale plugin
   - Has `go.mod` with a replace directive pointing to the vendored plugin
   - Uses Go 1.25.1 from nixpkgs-unstable via `buildGo125Module`

2. **Vendored Plugin** (`packages/caddy-tailscale-plugin/`):
   - Local copy of the tailscale/caddy-tailscale repository
   - Allows OAuth-enabled builds without depending on upstream changes
   - Can be customized for specific needs

### Key Nix Techniques

1. **Go Version Handling**:
   - Uses `buildGo125Module` which provides Go 1.25.1 from nixpkgs-unstable
   - Required because `tailscale.com@v1.88.2` needs Go >= 1.25.1
   - Fully reproducible builds with sandbox enabled (no runtime toolchain downloads)

2. **Local Module Replacement**:
   - `postPatch` hook copies the plugin source to the build directory
   - Go's replace directive in `go.mod` uses relative path: `../caddy-tailscale-plugin`
   - This approach avoids network access during build

3. **Vendor Hash Computation**:
   - Initial build with `vendorHash = lib.fakeHash` computes the correct hash
   - Hash is then hardcoded for reproducible builds

## Usage

### Building the Package

```bash
# Build the package
nix build '.#caddy-tailscale'

# Or using nix-build
nix-build -E 'with import <nixpkgs> {}; callPackage ./packages/caddy-tailscale/default.nix {}'
```

### Verifying the Build

```bash
# Check version
./result/bin/caddy-with-tailscale version

# List modules (should show tailscale modules)
./result/bin/caddy-with-tailscale list-modules | grep tailscale
```

Expected modules:
- `tls.get_certificate.tailscale`
- `http.authentication.providers.tailscale`
- `http.reverse_proxy.transport.tailscale`
- `tailscale`

### Using in NixOS Configuration

Add to your NixOS configuration:

```nix
services.caddy = {
  enable = true;
  package = pkgs.caddy-tailscale;
  # ... your Caddy configuration
};
```

## Configuration Examples

### Tailscale OAuth Authentication

```caddyfile
example.com {
  tailscale_auth
  reverse_proxy localhost:8080
}
```

With environment variables:
- `TS_AUTHKEY`: Tailscale auth key for the Caddy instance
- `TS_API_CLIENT_ID`: OAuth client ID from Tailscale admin console
- `TS_API_CLIENT_SECRET`: OAuth client secret from Tailscale admin console

### Tailscale TLS Certificates

```caddyfile
{
  tailscale
}

myhost {
  respond "Hello from Tailscale!"
}
```

## Development

### Updating the Plugin

To update the vendored plugin:

```bash
cd packages/caddy-tailscale-plugin
# Update source files or pull latest from upstream
cd ..
```

Then rebuild with `vendorHash = lib.fakeHash` to get the new hash.

### Updating Dependencies

```bash
cd packages/caddy-tailscale
nix-shell -p go --run "go get -u ./... && go mod tidy"
```

Then rebuild with `vendorHash = lib.fakeHash` to compute the new hash.

### Troubleshooting

**Error: `hash mismatch in fixed-output derivation`**
- This is expected when using `lib.fakeHash`
- Copy the reported `got:` hash to `vendorHash` in `default.nix`

**Plugin not found in modules list**
- Verify `go.mod` replace directive points to correct path
- Check that `postPatch` successfully copies the plugin
- Ensure `main.go` imports `github.com/tailscale/caddy-tailscale`

## References

- [Caddy Documentation](https://caddyserver.com/docs/)
- [tailscale/caddy-tailscale Plugin](https://github.com/tailscale/caddy-tailscale)
- [Tailscale OAuth Documentation](https://tailscale.com/kb/1240/sso-oauth-clients/)
- [NixOS Caddy Module](https://search.nixos.org/options?query=services.caddy)

## License

- Caddy: Apache 2.0
- Tailscale Plugin: Apache 2.0
