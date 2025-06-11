# Supabase Module

## Overview

The Supabase module provides a generic, scalable way to host multiple Supabase instances on a single host. It integrates with the existing constellation architecture, gateway system, and agenix secret management to provide a streamlined deployment experience.

## Architecture

### Module Structure
```
modules/supabase/
├── default.nix          # Main module configuration
├── instance.nix         # Individual instance configuration
├── secrets.nix          # Secret management automation
└── scripts/
    ├── create-instance   # Instance creation script
    ├── update-secret     # Secret update script
    └── delete-instance   # Instance cleanup script
```

### Key Components

1. **Multi-Instance Management**: Support for multiple Supabase instances per host
2. **Gateway Integration**: Automatic subdomain routing via media gateway
3. **Secret Automation**: Automated secret generation and management
4. **Database Isolation**: Separate PostgreSQL databases per instance
5. **Configuration Templates**: Pre-configured settings for common use cases

## Configuration

### Basic Usage

```nix
# hosts/cloud/configuration.nix
{
  imports = [ ../../modules/supabase ];
  
  constellation.supabase.enable = true;
  
  constellation.supabase.instances = {
    # Production instance
    prod = {
      enable = true;
      subdomain = "supabase";           # supabase.rosenfeld.one
      jwtSecret = "supabase-prod-jwt";  # Reference to agenix secret
      anonKey = "supabase-prod-anon";   # Reference to agenix secret
      serviceKey = "supabase-prod-service"; # Reference to agenix secret
      databaseUrl = "supabase-prod-db"; # Reference to agenix secret
    };
    
    # Development instance
    dev = {
      enable = true;
      subdomain = "supabase-dev";       # supabase-dev.rosenfeld.one
      jwtSecret = "supabase-dev-jwt";
      anonKey = "supabase-dev-anon";
      serviceKey = "supabase-dev-service";
      databaseUrl = "supabase-dev-db";
    };
  };
}
```

### Instance Options

Each instance supports the following configuration:

```nix
{
  enable = true;                    # Enable this instance
  subdomain = "supabase";          # Subdomain for gateway routing
  
  # Secret references (agenix secret names)
  jwtSecret = "supabase-jwt";      # JWT secret for authentication
  anonKey = "supabase-anon";       # Anonymous API key
  serviceKey = "supabase-service"; # Service role API key
  databaseUrl = "supabase-db";     # PostgreSQL connection string
  
  # Optional configuration
  port = 8000;                     # Custom port (auto-assigned if not specified)
  logLevel = "info";               # Log level (debug, info, warn, error)
  
  # Database configuration
  database = {
    name = "supabase_prod";        # Database name (defaults to instance name)
    user = "supabase";             # Database user
    createDatabase = true;         # Auto-create database
  };
  
  # Storage configuration
  storage = {
    enable = true;                 # Enable storage service
    bucket = "supabase-storage";   # Default storage bucket
  };
  
  # Additional services
  services = {
    realtime = true;               # Enable realtime subscriptions
    auth = true;                   # Enable authentication service
    restApi = true;                # Enable REST API
    storage = true;                # Enable storage service
  };
}
```

## Secret Management

### Automated Secret Generation

The module provides scripts to automate secret management:

```bash
# Create a new instance with auto-generated secrets
just supabase-create prod

# Update secrets for an existing instance
just supabase-update-secret prod jwt

# Rotate all secrets for an instance
just supabase-rotate-secrets prod
```

### Secret Structure

Each instance requires four secrets:

1. **JWT Secret**: Used for signing JWT tokens
2. **Anon Key**: Public API key for client-side access
3. **Service Key**: Server-side API key with elevated permissions
4. **Database URL**: PostgreSQL connection string

### Agenix Integration

Secrets are automatically added to `secrets/secrets.nix`:

```nix
{
  # Supabase secrets
  "supabase-prod-jwt.age".publicKeys = users ++ [cloud];
  "supabase-prod-anon.age".publicKeys = users ++ [cloud];
  "supabase-prod-service.age".publicKeys = users ++ [cloud];
  "supabase-prod-db.age".publicKeys = users ++ [cloud];
  
  "supabase-dev-jwt.age".publicKeys = users ++ [cloud];
  "supabase-dev-anon.age".publicKeys = users ++ [cloud];
  "supabase-dev-service.age".publicKeys = users ++ [cloud];
  "supabase-dev-db.age".publicKeys = users ++ [cloud];
}
```

## Gateway Integration

### Automatic Routing

The module automatically registers instances with the media gateway:

```nix
# Automatically generated gateway configuration
media.gateway.services = {
  supabase-prod = {
    enable = true;
    host = "127.0.0.1";
    port = 8000;
    subdomain = "supabase";
    settings = {
      reverse_proxy = true;
      websocket_support = true;
    };
  };
  
  supabase-dev = {
    enable = true;
    host = "127.0.0.1";
    port = 8001;
    subdomain = "supabase-dev";
    settings = {
      reverse_proxy = true;
      websocket_support = true;
    };
  };
};
```

### SSL/TLS Configuration

SSL certificates are automatically managed through the gateway's ACME integration.

## Database Management

### PostgreSQL Integration

Each instance gets its own PostgreSQL database:

```nix
services.postgresql = {
  enable = true;
  databases = [
    "supabase_prod"
    "supabase_dev"
  ];
  
  users = [
    {
      name = "supabase_prod";
      database = "supabase_prod";
      passwordFile = "/path/to/secret";
    }
    {
      name = "supabase_dev";
      database = "supabase_dev";
      passwordFile = "/path/to/secret";
    }
  ];
};
```

### Database Isolation

Each instance operates with:
- Separate database
- Separate user account
- Isolated permissions
- Independent backups

## Automation Scripts

### Just Commands

Add to `justfile`:

```bash
# Supabase management commands
supabase-create INSTANCE:
    scripts/supabase/create-instance {{INSTANCE}}

supabase-delete INSTANCE:
    scripts/supabase/delete-instance {{INSTANCE}}

supabase-update-secret INSTANCE SECRET:
    scripts/supabase/update-secret {{INSTANCE}} {{SECRET}}

supabase-rotate-secrets INSTANCE:
    scripts/supabase/rotate-secrets {{INSTANCE}}

supabase-status:
    scripts/supabase/status
```

### Script Functionality

1. **create-instance**: 
   - Generates all required secrets
   - Updates agenix configuration
   - Creates database
   - Encrypts and stores secrets
   - Updates NixOS configuration

2. **update-secret**:
   - Regenerates specific secret
   - Re-encrypts with agenix
   - Triggers configuration rebuild

3. **delete-instance**:
   - Removes secrets from agenix
   - Drops database
   - Cleans up configuration

4. **rotate-secrets**:
   - Regenerates all secrets for an instance
   - Maintains service continuity

## Implementation Plan

### Phase 1: Core Module
- [x] Analyze existing patterns
- [x] Design module structure
- [ ] Implement basic module (`modules/supabase/default.nix`)
- [ ] Create instance configuration (`modules/supabase/instance.nix`)

### Phase 2: Secret Management
- [ ] Implement secret generation scripts
- [ ] Create agenix integration (`modules/supabase/secrets.nix`)
- [ ] Add just commands to justfile

### Phase 3: Gateway Integration
- [ ] Integrate with media gateway
- [ ] Add automatic service registration
- [ ] Configure SSL/TLS handling

### Phase 4: Database Management
- [ ] Implement PostgreSQL integration
- [ ] Add database creation/management
- [ ] Configure backup integration

### Phase 5: Testing & Documentation
- [ ] Test with cloud host
- [ ] Create usage examples
- [ ] Document troubleshooting

## Usage Examples

### Creating a New Instance

```bash
# Create production instance
just supabase-create prod

# This will:
# 1. Generate JWT secret, anon key, service key, and database URL
# 2. Encrypt secrets with agenix
# 3. Update secrets.nix
# 4. Create PostgreSQL database
# 5. Update configuration to enable the instance
```

### Updating Configuration

```nix
# Add to hosts/cloud/configuration.nix
constellation.supabase.instances.prod = {
  enable = true;
  subdomain = "api";  # Change subdomain
  logLevel = "debug"; # Enable debug logging
  
  # Enable additional services
  services.realtime = true;
  services.storage = true;
};
```

### Accessing the Instance

After deployment:
- Web Interface: `https://supabase.rosenfeld.one`
- API Endpoint: `https://supabase.rosenfeld.one/rest/v1/`
- Realtime: `wss://supabase.rosenfeld.one/realtime/v1/websocket`

## Security Considerations

1. **Secret Rotation**: Regular rotation of JWT secrets and API keys
2. **Database Isolation**: Each instance has isolated database access
3. **Network Security**: Services bound to localhost, exposed via gateway
4. **Access Control**: Integration with Authelia for admin access
5. **Backup Security**: Encrypted backups of databases and secrets

## Troubleshooting

### Common Issues

1. **Secret Decryption Errors**: Ensure host key is in secrets.nix
2. **Database Connection**: Check PostgreSQL service status
3. **Gateway Routing**: Verify subdomain configuration
4. **Port Conflicts**: Use automatic port assignment

### Debug Commands

```bash
# Check service status
systemctl status supabase-prod

# View logs
journalctl -u supabase-prod -f

# Test database connection
psql -h localhost -U supabase_prod -d supabase_prod

# Verify secrets
agenix -d secrets/supabase-prod-jwt.age
```

This plan provides a comprehensive approach to implementing a generic, scalable Supabase module that integrates seamlessly with the existing NixOS constellation architecture.