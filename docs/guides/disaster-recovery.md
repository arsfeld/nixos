# Disaster Recovery

This guide provides concrete commands and procedures for recovering from various failure scenarios. Keep this document accessible offline.

## Prerequisites

### Recovery Tools
- NixOS installation USB/ISO
- Access to backup locations
- Age keys for decrypting secrets
- Network access to Tailscale

### Critical Information
```bash
# Backup locations
PRIMARY_BACKUP="storage.bat-boa.ts.net:/mnt/data/backup"
S3_BACKUP="s3://backup-bucket"
REMOTE_BACKUP="rclone:idrive:/nixos-backup"

# Repository
REPO="https://github.com/arsfeld/nixos.git"
```

### Host Disk Configuration
```bash
# Hosts using disko (automated partitioning)
DISKO_HOSTS="storage hpe g14 router"

# Default devices for disko hosts
# storage: /dev/nvme0n1 (or check disko-config.nix)
# hpe: /dev/sda
# g14: check disko-config.nix
# router: /dev/nvme0n1

# Hosts requiring manual partitioning
MANUAL_HOSTS="cloud raider striker core micro raspi3 r2s"
```

## Scenario 1: Storage Server Failure

The storage server hosts most services. Recovery priority is critical.

### 1.1 Complete Hardware Failure

#### Boot from NixOS ISO
```bash
# Download and create bootable USB
wget https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-x86_64-linux.iso
dd if=latest-nixos-minimal-x86_64-linux.iso of=/dev/sdX bs=4M status=progress
```

#### Partition New Disk

For hosts with disko configuration (storage, hpe, g14, router):

```bash
# Clone repository to get disko config
git clone $REPO /tmp/nixos-config

# For storage server (adjust device name as needed)
nix run github:nix-community/disko -- \
  --mode disko \
  --flake /tmp/nixos-config#storage \
  /dev/nvme0n1

# For other disko-enabled hosts
# hpe: /dev/sda
# g14: check disko-config.nix for device
# router: /dev/nvme0n1
```

For hosts without disko configuration:
```bash
# Create partitions manually
parted /dev/nvme0n1 -- mklabel gpt
parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 512MiB
parted /dev/nvme0n1 -- mkpart primary 512MiB -16GiB
parted /dev/nvme0n1 -- mkpart primary linux-swap -16GiB 100%
parted /dev/nvme0n1 -- set 1 esp on

# Format partitions
mkfs.fat -F 32 -n ESP /dev/nvme0n1p1
mkfs.btrfs -L nixos /dev/nvme0n1p2
mkswap -L swap /dev/nvme0n1p3

# Mount filesystems
mount /dev/nvme0n1p2 /mnt
mkdir -p /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot
swapon /dev/nvme0n1p3

# Create Btrfs subvolumes (if using Btrfs)
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@nix
btrfs subvolume create /mnt/@var-lib
btrfs subvolume create /mnt/@var-log

# Remount with subvolumes
umount /mnt
mount -o compress=zstd:3,subvol=@ /dev/nvme0n1p2 /mnt
mkdir -p /mnt/{home,nix,var/lib,var/log,boot}
mount -o compress=zstd:3,subvol=@home /dev/nvme0n1p2 /mnt/home
mount -o compress=zstd:3,subvol=@nix /dev/nvme0n1p2 /mnt/nix
mount -o compress=zstd:3,subvol=@var-lib /dev/nvme0n1p2 /mnt/var/lib
mount -o compress=zstd:3,subvol=@var-log /dev/nvme0n1p2 /mnt/var/log
mount /dev/nvme0n1p1 /mnt/boot
```

#### Restore System Configuration
```bash
# Enable networking
systemctl start dhcpcd
# Or manually:
ip addr add 192.168.1.10/24 dev eth0
ip route add default via 192.168.1.1

# Install git and age
nix-env -iA nixos.git nixos.age

# For non-disko hosts, clone to /mnt
cd /mnt
git clone $REPO

# For non-disko hosts only: generate hardware config
nixos-generate-config --root /mnt
cp /mnt/etc/nixos/hardware-configuration.nix /mnt/nixos/hosts/storage/

# Install NixOS
# For disko hosts (storage, hpe, g14, router):
nixos-install --flake /tmp/nixos-config#storage --no-root-passwd

# For non-disko hosts:
nixos-install --flake /mnt/nixos#storage --no-root-passwd

# Set root password
nixos-enter
passwd
exit

# Reboot
reboot
```

#### Restore Data from Backup
```bash
# After reboot, install rustic
nix-env -iA nixpkgs.rustic

# Configure backup credentials
export RUSTIC_PASSWORD=$(cat /path/to/backup-password)
export AWS_ACCESS_KEY_ID=your-key
export AWS_SECRET_ACCESS_KEY=your-secret

# List snapshots
rustic -r s3:s3.amazonaws.com/backup-bucket snapshots

# Restore data directories
rustic -r s3:s3.amazonaws.com/backup-bucket restore latest --target / --include '/mnt/data/files'

# For large media files (if backed up separately)
rsync -avP backup-server:/path/to/media/ /mnt/data/media/
```

### 1.2 Disk Failure (Data Array)

#### Create Bcachefs Array
```bash
# Install bcachefs tools
nix-env -iA nixpkgs.bcachefs-tools

# Create new bcachefs filesystem on replacement disks
bcachefs format \
  --compression=zstd \
  --replicas=2 \
  --label=data \
  /dev/sda /dev/sdb /dev/sdc /dev/sdd

# Mount the filesystem
mount -t bcachefs /dev/sda:/dev/sdb:/dev/sdc:/dev/sdd /mnt/data

# Create directory structure
mkdir -p /mnt/data/{media,files,backup}

# Restore from backup
rustic -r /mnt/data/backup/rustic restore latest --target /mnt/data/files
```

## Scenario 2: Cloud Server Failure

The cloud server hosts authentication services. Recovery is critical for access.

### 2.1 VM Recovery (Oracle Cloud)

#### Create New Instance
```bash
# Using Oracle Cloud CLI
oci compute instance launch \
  --availability-domain "US-ASHBURN-AD-1" \
  --compartment-id $COMPARTMENT_ID \
  --shape "VM.Standard.A1.Flex" \
  --shape-config '{"memoryInGBs": 24, "ocpus": 4}' \
  --image-id $UBUNTU_IMAGE_ID \
  --subnet-id $SUBNET_ID \
  --display-name "cloud-new"
```

#### Initial Setup
```bash
# SSH to new instance
ssh ubuntu@new-instance-ip

# Install Nix
sh <(curl -L https://nixos.org/nix/install) --daemon

# Install NixOS
sudo mkdir -p /mnt
sudo mount /dev/sda1 /mnt
git clone $REPO
sudo nixos-install --flake ./nixos#cloud --root /mnt

# Configure networking
sudo tee /mnt/etc/nixos/networking.nix << 'EOF'
{
  networking = {
    hostName = "cloud";
    interfaces.enp0s6.ipv4.addresses = [{
      address = "10.0.0.33";
      prefixLength = 24;
    }];
    defaultGateway = "10.0.0.1";
    nameservers = [ "8.8.8.8" ];
  };
}
EOF
```

#### Restore Services
```bash
# Restore authentication data
rustic -r s3:s3.amazonaws.com/backup-bucket restore latest \
  --target / \
  --include '/var/lib/lldap' \
  --include '/var/lib/authelia' \
  --include '/var/lib/containers'

# Start critical services
systemctl start podman-lldap
systemctl start podman-authelia
systemctl start podman-dex
systemctl start caddy
```

### 2.2 Quick Migration to Storage Server

If cloud server fails but storage is available:

```bash
# On storage server, temporarily run auth services
cd /home/user/nixos

# Create temporary configuration
cat > hosts/storage/emergency-auth.nix << 'EOF'
{ config, ... }:
{
  # Import cloud services temporarily
  imports = [ ../cloud/services/auth.nix ];
  
  # Adjust ports if needed to avoid conflicts
  services.authelia.port = 9092;
}
EOF

# Deploy with emergency config
sudo nixos-rebuild switch --flake .#storage

# Update DNS or Tailscale to point to storage server
```

## Scenario 3: Router Failure

Network connectivity is critical. Have backup router (R2S) ready.

### 3.1 Activate Backup Router (R2S)

```bash
# Connect R2S to network
# Default IP: 192.168.1.1

# SSH to R2S (or connect serial console)
ssh root@192.168.1.1

# Update configuration
cd /etc/nixos
git pull

# Activate full router config
nixos-rebuild switch --flake .#r2s-router

# Restart services
systemctl restart nftables
systemctl restart blocky
systemctl restart dhcpcd
```

### 3.2 Build New Router

```bash
# Boot NixOS installer
# Router uses disko configuration

# Clone repository
git clone $REPO /tmp/nixos-config

# Run disko to partition (usually /dev/nvme0n1 for router)
nix run github:nix-community/disko -- \
  --mode disko \
  --flake /tmp/nixos-config#router \
  /dev/nvme0n1

# Install NixOS
nixos-install --flake /tmp/nixos-config#router

# Configure network interfaces if needed
# Edit /mnt/nixos/hosts/router/network.nix with correct interface names
```

## Scenario 4: Complete Infrastructure Loss

If everything is lost, rebuild in priority order:

### 4.1 Priority Order
1. **Router**: Network connectivity
2. **Storage**: Core services and data
3. **Cloud**: Authentication and public services

### 4.2 Bootstrap Process

```bash
# 1. Set up temporary router (can be any Linux box)
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
echo 1 > /proc/sys/net/ipv4/ip_forward

# 2. Build storage server with minimal config
git clone $REPO
cd nixos
# Temporarily disable services in configuration
nixos-install --flake .#storage-minimal

# 3. Restore backups to storage
# Download from cloud backup if local is lost
rclone copy idrive:/nixos-backup/latest /mnt/data/restore

# 4. Build remaining infrastructure
# Now with storage online, rebuild other hosts normally
```

## Recovery Commands Reference

### Backup Operations

```bash
# List all backups
rustic -r $BACKUP_REPO snapshots

# Restore specific snapshot
rustic -r $BACKUP_REPO restore <snapshot-id> --target /restore

# Restore specific paths
rustic -r $BACKUP_REPO restore latest --target / --include '/var/lib/postgresql'

# Mount backup for browsing
rustic -r $BACKUP_REPO mount /mnt/backup-browse
```

### Service Recovery

```bash
# Database recovery
systemctl stop postgresql
psql -U postgres < /backup/postgresql_dump.sql
systemctl start postgresql

# Container recovery
podman load < /backup/container-images.tar
cd /var/lib/containers
tar -xzf /backup/container-volumes.tar.gz

# Secret recovery
age -d -i ~/.config/age/keys.txt < secrets.age > secrets.env
```

### Network Diagnostics

```bash
# Test connectivity
ping -c 4 8.8.8.8
curl -I https://auth.arsfeld.one

# Check services
systemctl status caddy authelia lldap
podman ps -a

# Tailscale recovery
tailscale up --authkey=$TAILSCALE_AUTHKEY
tailscale status
```

## Automation Scripts

### Quick Recovery Script

Create `/root/disaster-recovery.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

HOSTNAME=$(hostname)
BACKUP_REPO="s3://backup-bucket"

echo "Starting disaster recovery for $HOSTNAME..."

# Install required tools
nix-env -iA nixpkgs.rustic nixpkgs.age nixpkgs.git

# Restore system files
echo "Restoring /etc..."
rustic -r $BACKUP_REPO restore latest --target / --include "/etc"

# Restore service data
echo "Restoring service data..."
case $HOSTNAME in
  storage)
    rustic -r $BACKUP_REPO restore latest --target / --include "/mnt/data/files"
    ;;
  cloud)
    rustic -r $BACKUP_REPO restore latest --target / --include "/var/lib/lldap" --include "/var/lib/authelia"
    ;;
esac

# Rebuild system
echo "Rebuilding NixOS configuration..."
nixos-rebuild switch

echo "Recovery complete! Please verify services."
```

### Health Check Script

```bash
#!/usr/bin/env bash
# /root/health-check.sh

check_service() {
  if systemctl is-active --quiet $1; then
    echo "✓ $1 is running"
  else
    echo "✗ $1 is not running"
    return 1
  fi
}

# Core services
check_service sshd
check_service tailscaled

# Host-specific services
case $(hostname) in
  storage)
    check_service postgresql
    check_service podman-plex
    check_service podman-nextcloud
    ;;
  cloud)
    check_service podman-lldap
    check_service podman-authelia
    check_service caddy
    ;;
  router)
    check_service nftables
    check_service blocky
    ;;
esac
```

## Important Notes

1. **Test Recovery Procedures**: Practice these procedures quarterly
2. **Keep Offline Copies**: Print or save this guide offline
3. **Update After Changes**: Keep recovery procedures current
4. **Document Credentials**: Store recovery passwords securely
5. **Verify Backups**: Regularly test backup restoration

## Emergency Contacts

- **ISP Support**: For network issues
- **Hardware Vendor**: For warranty replacements
- **Cloud Provider**: For VM issues
- **Backup Provider**: For storage access