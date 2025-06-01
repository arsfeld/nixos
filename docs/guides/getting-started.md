# Getting Started

## Prerequisites

Before working with this NixOS infrastructure, ensure you have:

### Required Software
- **Nix**: Package manager (with flakes enabled)
- **Git**: Version control
- **SSH**: Remote access
- **Age**: Secret encryption

### Recommended Software
- **Direnv**: Automatic environment loading
- **Just**: Command runner
- **Tailscale**: VPN access

## Initial Setup

### 1. Clone the Repository

```bash
git clone https://github.com/arsfeld/nixos.git
cd nixos
```

### 2. Enter Development Environment

```bash
# Using nix develop
nix develop

# Or with direnv
direnv allow
```

This provides all necessary tools:
- `deploy-rs`: Remote deployment
- `agenix`: Secret management
- `alejandra`: Nix formatter
- `attic`: Binary cache client

### 3. Configure Secrets Access

#### Generate Age Key
```bash
age-keygen -o ~/.config/agenix/keys.txt
```

#### Add Your Key
Add your public key to the appropriate secrets in `secrets/secrets.nix`:
```nix
{
  "mysecret.age".publicKeys = [ 
    "age1..." # Your public key
  ];
}
```

### 4. Set Up Tailscale Access

Install and authenticate Tailscale:
```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate
sudo tailscale up

# Verify connectivity
tailscale status
```

## Understanding the Structure

### Directory Layout
```
nixos/
├── flake.nix           # Flake definition
├── deploy.nix          # Deployment configuration
├── hosts/              # Per-host configurations
│   ├── storage/        # Storage server
│   ├── cloud/          # Cloud server
│   └── ...
├── modules/            # Reusable modules
│   └── constellation/  # Shared modules
├── home/               # Home-manager configs
├── secrets/            # Encrypted secrets
└── justfile           # Common commands
```

### Key Concepts

#### Flakes
Nix flakes provide reproducible builds:
```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Other inputs...
  };
  
  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations = {
      storage = nixpkgs.lib.nixosSystem {
        # Configuration...
      };
    };
  };
}
```

#### Modules
Modules encapsulate functionality:
```nix
{ config, lib, pkgs, ... }:
{
  options = {
    myModule.enable = lib.mkEnableOption "my module";
  };
  
  config = lib.mkIf config.myModule.enable {
    # Implementation
  };
}
```

## Common Tasks

### Building a Configuration

Test build without deploying:
```bash
# Build specific host
nix build .#nixosConfigurations.storage.config.system.build.toplevel

# Build and show what would change
nixos-rebuild build --flake .#storage
```

### Deploying Changes

Deploy to a single host:
```bash
just deploy storage
```

Deploy to multiple hosts:
```bash
just deploy storage cloud
```

Deploy with boot activation:
```bash
just boot storage
```

### Managing Secrets

#### Create New Secret
```bash
# Create secret file
echo "my-secret-value" > /tmp/secret.txt

# Encrypt it
agenix -e secrets/mysecret.age < /tmp/secret.txt

# Clean up
rm /tmp/secret.txt
```

#### Edit Existing Secret
```bash
agenix -e secrets/mysecret.age
```

#### Use in Configuration
```nix
{
  age.secrets.mysecret = {
    file = ../secrets/mysecret.age;
    owner = "myservice";
  };
  
  services.myservice = {
    passwordFile = config.age.secrets.mysecret.path;
  };
}
```

### Adding a Service

1. **Define in constellation services**:
```nix
# modules/constellation/services.nix
services.myapp = {
  host = "storage";
  port = 8080;
  public = true;
};
```

2. **Configure the container**:
```nix
# hosts/storage/services/myapp.nix
virtualisation.oci-containers.containers.myapp = {
  image = "myapp:latest";
  ports = ["8080:8080"];
  volumes = ["/mnt/data/myapp:/config"];
};
```

3. **Deploy**:
```bash
just deploy storage
```

## Development Workflow

### 1. Make Changes
Edit configuration files as needed.

### 2. Format Code
```bash
just fmt
```

### 3. Test Locally
```bash
# Build without deploying
nix build .#nixosConfigurations.hostname.config.system.build.toplevel
```

### 4. Deploy
```bash
just deploy hostname
```

### 5. Verify
- Check service status
- Monitor logs
- Test functionality

## Troubleshooting

### Build Failures

#### Check Flake Inputs
```bash
nix flake metadata
nix flake check
```

#### Update Dependencies
```bash
nix flake update
```

### Deployment Issues

#### SSH Connection
```bash
# Test SSH connection
ssh root@hostname.bat-boa.ts.net

# Check Tailscale
tailscale ping hostname
```

#### Service Problems
```bash
# Check service status
systemctl status servicename

# View logs
journalctl -u servicename -f

# Container issues
podman ps -a
podman logs containername
```

### Secret Decryption

#### Verify Key Access
```bash
# List authorized keys
agenix -e secrets/secrets.nix
```

#### Check Permissions
```bash
# On target host
ls -la /run/agenix/
```

## Best Practices

### 1. Test Before Deploy
Always build locally before deploying to production.

### 2. Use Version Control
Commit changes with meaningful messages:
```bash
git add .
git commit -m "feat(storage): add new media service"
```

### 3. Document Changes
Update documentation when adding new services or modules.

### 4. Monitor After Deploy
Check monitoring dashboards after deployment.

### 5. Backup Before Major Changes
Ensure backups are current before significant updates.

## Next Steps

1. **[Add a New Host](new-host.md)** - Set up a new system
2. **[Add a Service](new-service.md)** - Deploy a new application
3. **[Service Catalog](../services/catalog.md)** - Explore available services
4. **[Architecture Overview](../architecture/overview.md)** - Understand the system design

## Getting Help

### Documentation
- This documentation site
- NixOS manual: https://nixos.org/manual/
- Module source code

### Debugging
```bash
# Verbose deployment
deploy --debug-logs --targets .#hostname

# Nix repl for testing
nix repl
:l <nixpkgs>
```

### Community
- NixOS Discourse: https://discourse.nixos.org/
- NixOS Matrix/IRC: #nixos
- GitHub Issues: Project repository