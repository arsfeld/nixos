# Adding a New Service

This guide walks through adding a new service to the infrastructure, from initial configuration to deployment.

## Prerequisites

- Access to the repository
- Understanding of the [constellation module system](../modules/constellation.md)
- Familiarity with Docker/Podman containers
- Age keys for secret management (if needed)

## Step-by-Step Process

### 1. Define the Service

First, add your service to the constellation services registry:

```nix
# modules/constellation/services.nix
{
  services.myapp = {
    host = "storage";        # Which host will run this
    port = 8080;            # Service port
    public = true;          # Internet accessible?
    bypassAuth = false;     # Requires authentication?
    tailscaleFunnel = false; # Expose via Tailscale?
  };
}
```

### 2. Create Service Configuration

Create a new service module in the appropriate host directory:

```nix
# hosts/storage/services/myapp.nix
{ config, pkgs, ... }:
{
  # Container definition
  virtualisation.oci-containers.containers.myapp = {
    image = "docker.io/organization/myapp:latest";
    
    ports = [ "8080:8080" ];
    
    volumes = [
      "/mnt/data/myapp:/config"
      "/mnt/media:/media:ro"  # Read-only media access
    ];
    
    environment = {
      TZ = "America/New_York";
      PUID = "1000";
      PGID = "1000";
    };
    
    # If the service needs secrets
    environmentFiles = [
      config.age.secrets.myapp-env.path
    ];
  };
  
  # Create data directory
  systemd.tmpfiles.rules = [
    "d /mnt/data/myapp 0755 1000 1000 -"
  ];
}
```

### 3. Import the Service Module

Add the service to the host's configuration:

```nix
# hosts/storage/configuration.nix
{
  imports = [
    # ... other imports
    ./services/myapp.nix
  ];
}
```

### 4. Add Secrets (if needed)

#### Create Secret File

```bash
# Create environment file
cat > /tmp/myapp-env << 'EOF'
API_KEY=your-api-key-here
SECRET_TOKEN=your-secret-token
DATABASE_URL=postgresql://user:pass@localhost/myapp
EOF

# Encrypt it
agenix -e secrets/myapp-env.age < /tmp/myapp-env

# Clean up
rm /tmp/myapp-env
```

#### Register Secret

```nix
# secrets/secrets.nix
{
  "myapp-env.age" = {
    publicKeys = [
      storage
      # ... other authorized keys
    ];
  };
}
```

#### Configure Secret in Service

```nix
# hosts/storage/configuration.nix
{
  age.secrets.myapp-env = {
    file = ../../secrets/myapp-env.age;
    owner = "root";
    group = "root";
  };
}
```

### 5. Configure Reverse Proxy

The Caddy configuration is automatically generated based on the service definition. However, you may need special configurations:

```nix
# For special Caddy configurations
constellation.services.myapp = {
  # ... existing config
  caddyExtraConfig = ''
    header {
      X-Custom-Header "value"
    }
    request_body {
      max_size 100MB
    }
  '';
};
```

### 6. Database Setup (if needed)

If your service needs a database:

```nix
# hosts/storage/services/db.nix
{
  services.postgresql = {
    ensureDatabases = [ "myapp" ];
    ensureUsers = [{
      name = "myapp";
      ensurePermissions = {
        "DATABASE myapp" = "ALL PRIVILEGES";
      };
    }];
  };
}
```

### 7. Deploy the Service

```bash
# Format the configuration
just fmt

# Deploy to the host
just deploy storage

# Monitor deployment
journalctl -f -u podman-myapp
```

### 8. Verify Deployment

#### Check Container Status
```bash
ssh storage.bat-boa.ts.net
podman ps | grep myapp
podman logs myapp
```

#### Test Service Access
```bash
# Internal test
curl -I http://storage.bat-boa.ts.net:8080

# External test (if public)
curl -I https://myapp.arsfeld.one
```

## Common Service Patterns

### Media Service

```nix
virtualisation.oci-containers.containers.media-app = {
  image = "linuxserver/app:latest";
  
  volumes = [
    "/mnt/data/app:/config"
    "/mnt/media/movies:/movies"
    "/mnt/media/tv:/tv"
    "/mnt/downloads:/downloads"
  ];
  
  environment = {
    PUID = "1000";
    PGID = "1000";
    TZ = "America/New_York";
  };
};
```

### Database-Connected Service

```nix
virtualisation.oci-containers.containers.webapp = {
  image = "webapp:latest";
  
  environment = {
    DATABASE_HOST = "storage.bat-boa.ts.net";
    DATABASE_PORT = "5432";
    DATABASE_NAME = "webapp";
    DATABASE_USER = "webapp";
  };
  
  environmentFiles = [
    config.age.secrets.webapp-db.path  # Contains DATABASE_PASSWORD
  ];
  
  dependsOn = [ "postgresql" ];
};
```

### Service with Persistence

```nix
{
  # Container definition
  virtualisation.oci-containers.containers.stateful-app = {
    volumes = [
      "app-data:/data"  # Named volume
      "/mnt/data/app/config:/config"  # Bind mount
    ];
  };
  
  # Backup configuration
  services.rustic.backups.storage.paths = [
    "/mnt/data/app"
    "/var/lib/containers/storage/volumes/app-data"
  ];
}
```

## Authentication Integration

### SSO Integration

For services that support headers-based auth:

```nix
environment = {
  AUTH_HEADER = "Remote-User";
  AUTH_EMAIL_HEADER = "Remote-Email";
  TRUSTED_PROXIES = "172.16.0.0/12";
};
```

### Bypass Authentication

For services that handle their own auth:

```nix
constellation.services.myapp = {
  bypassAuth = true;  # Skip Authelia
  # ... other config
};
```

### API Endpoint Bypass

For services with API endpoints:

```nix
constellation.services.myapp = {
  authBypassPaths = [
    "/api/*"
    "/webhook/*"
  ];
};
```

## Troubleshooting

### Service Won't Start

1. **Check logs**:
   ```bash
   podman logs myapp
   journalctl -u podman-myapp
   ```

2. **Verify image**:
   ```bash
   podman pull docker.io/organization/myapp:latest
   ```

3. **Check permissions**:
   ```bash
   ls -la /mnt/data/myapp
   ```

### Network Issues

1. **Test internal connectivity**:
   ```bash
   curl http://localhost:8080
   ```

2. **Check firewall**:
   ```bash
   sudo nft list ruleset | grep 8080
   ```

3. **Verify Caddy**:
   ```bash
   curl -v https://myapp.arsfeld.one
   ```

### Secret Problems

1. **Verify secret decryption**:
   ```bash
   sudo cat /run/agenix/myapp-env
   ```

2. **Check permissions**:
   ```bash
   ls -la /run/agenix/
   ```

## Best Practices

### 1. Use Official Images
Prefer official or well-maintained images from Docker Hub.

### 2. Pin Versions
Always specify explicit versions:
```nix
image = "nginx:1.25.3";  # Good
image = "nginx:latest";  # Avoid
```

### 3. Resource Limits
Set appropriate resource constraints:
```nix
extraOptions = [
  "--memory=2g"
  "--cpus=2"
];
```

### 4. Health Checks
Configure health checks when available:
```nix
extraOptions = [
  "--health-cmd='curl -f http://localhost:8080/health || exit 1'"
  "--health-interval=30s"
];
```

### 5. Logging
Configure appropriate log drivers:
```nix
log-driver = "journald";
extraOptions = [
  "--log-opt=tag={{.Name}}"
];
```

## Next Steps

- Add your service to the [service catalog](../services/catalog.md)
- Configure [monitoring](../architecture/services.md#monitoring-and-logging)
- Set up [backups](../architecture/backup.md)
- Document service-specific procedures