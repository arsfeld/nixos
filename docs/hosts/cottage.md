# Cottage Host

This document describes the setup and configuration of the "cottage" host, which is an x86_64 system primarily used for:

1. Hosting backups using Garage (S3-compatible storage)
2. Running media services as a backup Plex system (using the *arr stack)
3. All services running under its own domain: `arsfeld.com`

## Hardware Configuration

- Boot drive: NVMe SSD for the OS
- Storage array: Multiple HDDs in a ZFS RAID-Z configuration
- Intel CPU with hardware transcoding support

## Services

### Backup Services
- Garage S3-compatible object storage for backup destination
- Automated bucket creation for different backup types:
  - `system-backups` for system backups
  - `media-backups` for media file backups

### Media Services
- Plex media server with hardware transcoding
- *Arr stack for automated media management:
  - Radarr (movies)
  - Sonarr (TV shows)
  - Bazarr (subtitles)
  - Prowlarr (indexers)
- Overseerr for content requests
- Kavita for manga/comics
- Stash for adult content

## Network

- Domain: `arsfeld.com`
- Internal access via Tailscale
- SSL certificates via Let's Encrypt with Cloudflare DNS challenge

## Installation

To install this system:

1. Boot from a NixOS live USB/CD
2. Clone this repository
3. Update the device paths in `disko-config.nix` to match the actual hardware
4. Run the installation with:
   ```
   nix --extra-experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko ./hosts/cottage/disko-config.nix
   nixos-install --flake .#cottage
   ```

## Maintenance

- System updates are handled via standard NixOS mechanisms
- Backups run automatically on a schedule
- Media services are containerized for easy updates

## Garage Configuration

Garage is configured as the primary S3-compatible backup destination.

### Ports
- **3900**: S3 API endpoint
- **3901**: RPC (internal cluster communication)
- **3902**: Web endpoint for static hosting
- **3903**: Admin API

### Buckets
- `system-backups` for system backups
- `media-backups` for media file backups

### Access Keys
Access keys are created automatically by the `garage-init` service on first boot. To retrieve keys:
```bash
garage key list
garage key info backup-key
```

### Secrets
Credentials are stored securely using agenix:
- `garage-rpc-secret.age`: RPC secret for node communication
- `garage-admin-token.age`: Admin API authentication token