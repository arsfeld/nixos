# Multi-Domain Support in Constellation and Media Modules

This document explains how the Constellation and Media modules handle domains and how to configure them to support multiple domains across different hosts.

## Current Architecture

### Domain Configuration Structure

The system currently uses the following domain configuration:

1. **Primary Domain**: `arsfeld.one` - Used by storage host for media services
2. **Auth Domain**: `rosenfeld.one` - Used for authentication services  
3. **Secondary Domain**: `arsfeld.dev` - Used by cloud host for public services
4. **Tailscale Domain**: `bat-boa.ts.net` - Used for internal Tailscale access

### Module Architecture

#### Media Modules (`/modules/media/`)

The media modules provide infrastructure for media services with centralized configuration:

- **`config.nix`**: Defines base configuration options including:
  - `domain`: Primary domain for public-facing media services (default: `arsfeld.one`)
  - `tsDomain`: Tailscale domain for internal access (default: `bat-boa.ts.net`)
  - User/group management, directories, and ACME settings

- **`gateway.nix`**: Implements the media gateway with:
  - Service routing based on subdomain (`<service>.<domain>`)
  - Authentication integration with Authelia
  - SSL termination and certificate management
  - Tailscale integration via tsnsrv

- **`containers.nix`**: Manages containerized media services
- **`__utils.nix`**: Provides utility functions for generating Caddy and tsnsrv configurations

#### Constellation Modules (`/modules/constellation/`)

The constellation modules provide opt-in features and service configurations:

- **`services.nix`**: Central service registry that:
  - Defines services by host (cloud, storage)
  - Configures authentication bypass rules
  - Manages Tailscale Funnel exposure
  - Automatically generates media.gateway service configurations

- **`media.nix`**: Configures the media server stack
- **`blog.nix`** and **`plausible.nix`**: Examples of services with configurable domains

## Current Domain Usage

### Storage Host
- Uses `arsfeld.one` as primary domain
- Services accessible at: `jellyfin.arsfeld.one`, `plex.arsfeld.one`, etc.
- Also accessible via Tailscale: `jellyfin.bat-boa.ts.net`

### Cloud Host  
- Uses `arsfeld.dev` for public services
- Blog at: `blog.arsfeld.dev`
- Plausible at: `plausible.arsfeld.dev`
- Auth services use `rosenfeld.one`

### Cottage Host
- Currently has domain configuration disabled
- Intended to use `arsfeld.com` when enabled

## Adding Multi-Domain Support

The modules **already support** multiple domains through proper configuration. Here's how to enable different domains for different hosts:

### Method 1: Host-Specific Domain Configuration (Recommended)

Configure domains at the host level by overriding the media.config options:

```nix
# hosts/cottage/configuration.nix
{
  # Enable media services with cottage-specific domain
  media.config = {
    enable = true;
    domain = "arsfeld.com";  # Override default domain
    email = "admin@arsfeld.com";  # Override ACME email
  };

  # Enable constellation services
  constellation.services.enable = true;
  constellation.media.enable = true;
}
```

### Method 2: Per-Service Domain Override

For services that expose domain options (like blog and plausible):

```nix
# hosts/cottage/configuration.nix
{
  constellation.blog = {
    enable = true;
    domain = "blog.arsfeld.com";  # Service-specific domain
  };

  constellation.plausible = {
    enable = true;  
    domain = "analytics.arsfeld.com";
  };
}
```

### Method 3: Multiple Domains on Same Host

To run services on multiple domains from the same host, you'll need to:

1. Ensure ACME certificates are configured for all domains:

```nix
# hosts/storage/configuration.nix
{
  security.acme.certs = {
    "arsfeld.one" = {
      extraDomainNames = ["*.arsfeld.one"];
    };
    "arsfeld.com" = {
      extraDomainNames = ["*.arsfeld.com"];
    };
  };
}
```

2. Extend the media.gateway module to support multiple domains (currently requires module modification)

## Implementation Considerations

### What Works Now

1. **Different domains per host**: Each host can use a different domain by setting `media.config.domain`
2. **Service-specific domains**: Services with domain options (blog, plausible) can use custom domains
3. **Authentication**: Authelia supports multiple domains through its configuration
4. **SSL Certificates**: ACME can manage certificates for multiple domains

### Current Limitations

1. **Single domain per host**: The media.gateway currently assumes one domain per host
2. **Service registry**: The constellation.services module doesn't support domain overrides per service
3. **Hardcoded auth domain**: Some services have hardcoded references to specific domains

### Recommended Approach for Cottage

For the cottage host, the simplest approach is:

```nix
# hosts/cottage/configuration.nix
{
  # Use cottage-specific domain
  media.config = {
    enable = true;
    domain = "arsfeld.com";
    tsDomain = "cottage.bat-boa.ts.net";  # If using different Tailscale network
  };

  # Enable desired constellation modules
  constellation.services.enable = true;
  constellation.media.enable = true;
  
  # Services will be available at:
  # - jellyfin.arsfeld.com
  # - plex.arsfeld.com
  # - etc.
}
```

## Future Enhancements

To improve multi-domain support, consider:

1. **Extend media.gateway** to support multiple domains:
   ```nix
   media.gateway.domains = {
     primary = "arsfeld.one";
     secondary = "arsfeld.com";
   };
   ```

2. **Per-service domain mapping** in constellation.services:
   ```nix
   constellation.services.jellyfin.domain = "media.arsfeld.com";
   ```

3. **Domain aliases** for services accessible via multiple domains

4. **Unified domain management** module that centralizes all domain configuration

## Summary

The constellation and media modules provide a flexible architecture that already supports multiple domains through host-specific configuration. Each host can use its own domain by setting `media.config.domain`, and services will automatically be configured with the appropriate subdomains. For more complex multi-domain scenarios on a single host, some module extensions would be beneficial but are not required for the basic use case of different domains per host.