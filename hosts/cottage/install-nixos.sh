#!/usr/bin/env bash
# Automated NixOS installation script for cottage using nixos-infect
# This script converts TrueNAS SCALE to NixOS while preserving Tailscale state

set -euo pipefail

# Configuration
NIXOS_CHANNEL="${NIXOS_CHANNEL:-nixos-24.11}"
FLAKE_REPO="${FLAKE_REPO:-https://github.com/arsfeld/nixos.git}"  # Can be overridden
FLAKE_REF="${FLAKE_REF:-master}"  # Can be overridden
HOST_NAME="cottage"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
   exit 1
fi

log "Starting automated NixOS installation for cottage"
log "This will convert TrueNAS SCALE to NixOS"
echo ""
warn "This will COMPLETELY REPLACE TrueNAS SCALE with NixOS!"
warn "The data pool will remain untouched but unmounted"
echo ""
read -p "Are you sure you want to continue? Type 'yes' to proceed: " -r
echo
if [[ ! $REPLY == "yes" ]]; then
    error "Installation cancelled"
    exit 1
fi

# Step 1: Prepare ZFS dataset
log "Preparing ZFS dataset for NixOS..."
if zfs list boot-pool/ROOT/nixos &>/dev/null; then
    warn "Dataset boot-pool/ROOT/nixos already exists"
    read -p "Do you want to destroy and recreate it? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Destroying existing dataset..."
        zfs destroy -r boot-pool/ROOT/nixos || true
        log "Creating new dataset..."
        zfs create -o mountpoint=legacy boot-pool/ROOT/nixos
    fi
else
    log "Creating boot-pool/ROOT/nixos dataset..."
    zfs create -o mountpoint=legacy boot-pool/ROOT/nixos
fi

# Step 2: Save important state
log "Saving system state..."
BACKUP_DIR="/tmp/nixos-infect-backup"
mkdir -p "$BACKUP_DIR"

# Save Tailscale state if it exists
if [[ -d /var/lib/tailscale ]]; then
    log "Backing up Tailscale state..."
    cp -a /var/lib/tailscale "$BACKUP_DIR/" || warn "Failed to backup Tailscale state"
fi

# Save network configuration
log "Saving network configuration..."
ip addr show > "$BACKUP_DIR/network-config.txt"
ip route show > "$BACKUP_DIR/routes.txt"
cat /etc/resolv.conf > "$BACKUP_DIR/resolv.conf"

# Step 3: Create NixOS configuration files
log "Creating NixOS configuration..."
mkdir -p /etc/nixos

# Create a minimal configuration that imports from the flake
cat > /etc/nixos/configuration.nix << 'EOF'
# Temporary configuration for nixos-infect
# This will be replaced by the flake configuration after installation
{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # Basic system configuration
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  
  networking.hostName = "cottage";
  networking.hostId = "d4c0ffee";
  
  # Enable SSH for remote access
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };
  
  # Enable Tailscale
  services.tailscale.enable = true;
  
  # Basic packages
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    curl
  ];
  
  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;
  
  # Set your time zone
  time.timeZone = "America/Toronto";
  
  # This value determines the NixOS release
  system.stateVersion = "24.11";
}
EOF

# Create hardware configuration
cat > /etc/nixos/hardware-configuration.nix << 'EOF'
# Hardware configuration for cottage
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ehci_pci" "ahci" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ "zfs" ];
  boot.kernelModules = [ "kvm-intel" ];
  
  # ZFS root
  fileSystems."/" = {
    device = "boot-pool/ROOT/nixos";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/6F43-89F4";
    fsType = "vfat";
  };

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
EOF

# Step 4: Add NIXOS_LUSTRATE configuration
log "Configuring nixos-infect preservation list..."
cat > /etc/NIXOS_LUSTRATE << 'EOF'
etc/nixos
etc/resolv.conf
etc/ssh/ssh_host_*
var/lib/tailscale
root/.ssh
EOF

# Step 5: Download and run nixos-infect
log "Downloading nixos-infect..."
curl -L https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect -o /tmp/nixos-infect
chmod +x /tmp/nixos-infect

log "Running nixos-infect (this will take a while)..."
log "The system will reboot automatically when complete"
echo ""
warn "You may lose connection during the process"
warn "The system will be accessible via Tailscale after reboot"
echo ""

# Set environment variables for nixos-infect
export NIX_CHANNEL="$NIXOS_CHANNEL"
export NIXOS_IMPORT=./hardware-configuration.nix

# Create a post-install script that will run after reboot
cat > /tmp/post-install.sh << EOF
#!/usr/bin/env bash
# Post-installation setup script

set -euo pipefail

log() {
    echo "[\$(date +'%Y-%m-%d %H:%M:%S')] \$*"
}

log "Running post-installation setup..."

# Wait for network
sleep 10

# Clone the flake repository
log "Cloning configuration repository..."
git clone $FLAKE_REPO /tmp/nixos-config || {
    log "Failed to clone repository"
    exit 1
}

cd /tmp/nixos-config
git checkout $FLAKE_REF

# Copy the flake configuration
log "Installing flake configuration..."
mkdir -p /etc/nixos
cp -r . /etc/nixos/

# Rebuild with the flake
log "Rebuilding NixOS with flake configuration..."
nixos-rebuild switch --flake /etc/nixos#$HOST_NAME || {
    log "Failed to rebuild with flake"
    exit 1
}

log "Post-installation setup complete!"
log "The system is now running NixOS with your flake configuration"

# Clean up
rm -f /root/post-install.sh
rm -f /etc/systemd/system/post-install.service
systemctl daemon-reload
EOF

chmod +x /tmp/post-install.sh

# Create systemd service for post-install
cat > /etc/systemd/system/post-install.service << EOF
[Unit]
Description=NixOS Post-Installation Setup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/post-install.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Copy post-install script to location that will survive
cp /tmp/post-install.sh /root/post-install.sh
chmod +x /root/post-install.sh

# Enable the service
ln -sf /etc/systemd/system/post-install.service /etc/systemd/system/multi-user.target.wants/post-install.service

# Run nixos-infect
log "Starting nixos-infect..."
bash -x /tmp/nixos-infect 2>&1 | tee /tmp/nixos-infect.log

# If we get here, something went wrong (nixos-infect should reboot)
error "nixos-infect did not reboot the system as expected"
error "Check /tmp/nixos-infect.log for details"
exit 1