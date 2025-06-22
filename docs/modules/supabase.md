# Dynamic Supabase Instance Management

## Overview

This document outlines a new approach for managing Supabase instances dynamically on NixOS hosts, moving away from the current static NixOS module approach to a more flexible system that allows creating and managing instances at runtime.

## Goals

1. Remove Supabase configuration from NixOS repository
2. Enable dynamic creation/deletion of Supabase instances
3. Manage instances directly on the host system
4. Automatically configure Caddy reverse proxy for new instances
5. Maintain security through proper secret management

## Architecture

### Components

1. **Supabase Manager TUI** (`/usr/local/bin/supabase-manager`)
   - Terminal UI application written in Python
   - Self-contained with uv inline dependencies
   - Downloads Supabase Docker files from GitHub
   - Creates instance directories
   - Generates and manages secrets
   - Configures Docker Compose
   - Manages instance lifecycle
   - Real-time monitoring and logs

2. **Instance Storage** (`/var/lib/supabase/instances/`)
   - Each instance gets its own directory
   - Contains docker-compose.yml and configuration
   - Stores instance-specific secrets

3. **Caddy Integration**
   - Dynamic configuration directory watched by Caddy
   - Per-instance Caddyfile snippets
   - Automatic SSL with wildcard certificates

4. **State Management** (`/var/lib/supabase/state.json`)
   - Tracks all instances
   - Stores metadata (creation date, URLs, etc.)
   - Used for listing and management

### Directory Structure

```
/var/lib/supabase/
├── instances/
│   ├── project1/
│   │   ├── docker-compose.yml
│   │   ├── .env
│   │   ├── volumes/
│   │   └── kong.yml
│   └── project2/
│       └── ...
├── caddy/
│   ├── project1.conf
│   └── project2.conf
├── state.json
└── templates/
    └── (cached Supabase files)
```

## Implementation Plan

### Phase 1: Terminal UI Application

1. **Technology Stack**:
   - Python with uv for dependency management
   - Rich/Textual for terminal UI
   - Click for CLI framework
   - Docker SDK for container management
   - Shebang script with inline dependencies

2. **UI Features**:
   - **Dashboard View**:
     - List all instances with status indicators
     - Show resource usage (CPU, memory, disk)
     - Quick actions (start/stop/restart)
   - **Instance Detail View**:
     - Container status for all services
     - Real-time logs viewer
     - Environment variables editor
     - Database connection info
     - API endpoints and keys
   - **Create Instance Wizard**:
     - Name validation
     - Advanced options (custom ports, resource limits)
     - Secret generation preview
   - **Monitoring View**:
     - Resource graphs
     - Request metrics
     - Error logs

3. **Script Header Example**:
   ```python
   #!/usr/bin/env -S uv run --quiet --script
   # /// script
   # dependencies = [
   #   "textual>=0.47.0",
   #   "docker>=7.0.0",
   #   "rich>=13.0.0",
   #   "httpx>=0.25.0",
   #   "pyyaml>=6.0",
   # ]
   # ///
   ```

### Phase 2: NixOS Integration

1. **Minimal NixOS Module** (`modules/supabase-dynamic.nix`):
   ```nix
   {
     # Install docker and docker-compose
     virtualisation.docker.enable = true;
     
     # Install management script
     environment.systemPackages = [ supabase-manager ];
     
     # Create required directories
     systemd.tmpfiles.rules = [
       "d /var/lib/supabase 0755 root root -"
       "d /var/lib/supabase/instances 0755 root root -"
       "d /var/lib/supabase/caddy 0755 root root -"
     ];
     
     # Configure Caddy to watch dynamic config
     services.caddy = {
       enable = true;
       extraConfig = ''
         import /var/lib/supabase/caddy/*.conf
       '';
     };
   }
   ```

2. **Systemd Services**:
   - Service to ensure instances start on boot
   - Timer for periodic updates/maintenance

### Phase 3: Caddy Configuration

Each instance gets a Caddy config file using flat subdomain structure:
```
project1.arsfeld.dev {
  reverse_proxy localhost:8000
}

project1-studio.arsfeld.dev {
  reverse_proxy localhost:3000
}

project1-mail.arsfeld.dev {
  reverse_proxy localhost:54324
}
```

### Phase 4: Secret Management

1. Generate secrets on instance creation:
   - JWT secret
   - Anon key
   - Service role key
   - Database password
   - Dashboard password

2. Store secrets in:
   - Instance `.env` file (for Docker)
   - Encrypted backup for disaster recovery

## Domain Strategy

Using `*.arsfeld.dev` wildcard certificate, we'll use a flat subdomain hierarchy:
- API: `project1.arsfeld.dev`
- Studio: `project1-studio.arsfeld.dev`
- Inbucket: `project1-mail.arsfeld.dev`

This works perfectly with the wildcard certificate and keeps URLs simple.

## Advantages

- **Flexibility**: Add/remove instances without rebuilding NixOS
- **Speed**: No need to deploy entire system for changes
- **Isolation**: Each instance completely independent
- **Simplicity**: Fewer NixOS abstractions
- **Portability**: Easier to move instances between hosts

## Security Considerations

1. **File Permissions**: Restrict access to instance directories
2. **Network Isolation**: Use Docker networks per instance
3. **Secret Rotation**: Built-in secret rotation capability
4. **Audit Logging**: Log all management operations
5. **Backup Encryption**: Encrypt all backups

## Example Usage

```bash
# Launch the TUI
supabase-manager

# Direct CLI commands (bypasses TUI)
supabase-manager create myproject
supabase-manager list
supabase-manager delete myproject
```

### TUI Navigation

1. **Main Dashboard**:
   ```
   ┌─ Supabase Manager ─────────────────────────────┐
   │ Instances (3)                      [+] Create  │
   ├────────────────────────────────────────────────┤
   │ ● project1    Running   CPU: 12%  MEM: 512MB  │
   │ ● project2    Running   CPU: 8%   MEM: 384MB  │
   │ ○ project3    Stopped   CPU: 0%   MEM: 0MB    │
   └────────────────────────────────────────────────┘
   [Enter] Details  [S] Start/Stop  [D] Delete  [Q] Quit
   ```

2. **Instance Details**:
   ```
   ┌─ project1 ─────────────────────────────────────┐
   │ Status: Running                                │
   │ Created: 2025-01-15 10:30                      │
   │                                                │
   │ URLs:                                          │
   │   API:    https://project1.arsfeld.dev         │
   │   Studio: https://project1-studio.arsfeld.dev  │
   │   Mail:   https://project1-mail.arsfeld.dev    │
   │                                                │
   │ Containers:                                    │
   │   ✓ project1-db         (postgres:15)          │
   │   ✓ project1-kong       (kong:2.8)             │
   │   ✓ project1-auth       (supabase/gotrue)      │
   │   ✓ project1-realtime   (supabase/realtime)    │
   │   ✓ project1-rest       (postgrest/postgrest)  │
   │   ✓ project1-storage    (supabase/storage-api) │
   │                                                │
   │ [L] Logs  [E] Environment  [R] Restart  [B] Back │
   └────────────────────────────────────────────────┘
   ```

## Future Enhancements

1. Monitoring integration with Prometheus/Grafana
2. Automated backups to S3/B2
3. Multi-host support
4. Resource limits per instance
5. Usage metrics and billing
6. Instance templates for common configurations
7. Database migration tools
8. SSL certificate management per instance