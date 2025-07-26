#!/usr/bin/env bash
# Simplified NixOS installation script for cottage using nixos-infect
# This version prepares the full configuration before running nixos-infect

set -euo pipefail

# Configuration
NIXOS_CHANNEL="${NIXOS_CHANNEL:-nixos-24.11}"
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

# Step 2: Create NixOS configuration files
log "Creating NixOS configuration..."
mkdir -p /etc/nixos

# Create the main configuration - this is what will be used after nixos-infect
cat > /etc/nixos/configuration.nix << 'EOF'
# NixOS configuration for cottage
# Converted from TrueNAS SCALE using nixos-infect
{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # Boot configuration
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.supportedFilesystems = [ "zfs" ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelModules = [ "kvm-intel" "ip6_tables" ];
  
  # ZFS configuration
  boot.zfs = {
    forceImportRoot = false;
    forceImportAll = false;
    allowHibernation = false;
  };
  
  # Kernel parameters
  boot.kernelParams = [ 
    "zfs.zfs_scan_vdev_limit=16M"
    "nohibernate"
  ];
  
  # Networking
  networking.hostName = "cottage";
  networking.hostId = "d4c0ffee";
  networking.useDHCP = true;
  networking.nftables.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];
  
  # Don't wait for network during boot
  networking.dhcpcd = {
    wait = "background";
    extraConfig = ''
      timeout 10
      noipv6rs
      fallback
    '';
  };
  
  # SSH configuration
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = false;
    };
    startWhenNeeded = false;
  };
  
  # Ensure SSH starts even if network is degraded
  systemd.services.sshd = {
    wantedBy = [ "multi-user.target" ];
    after = lib.mkForce [ "network.target" ];
  };
  
  # Tailscale
  services.tailscale.enable = true;
  networking.firewall = {
    checkReversePath = "loose";
    trustedInterfaces = [ "tailscale0" ];
  };
  
  # Time and locale
  time.timeZone = "America/Toronto";
  i18n.defaultLocale = "en_CA.UTF-8";
  
  # Basic packages
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    curl
    htop
    tmux
    zsh
    fish
    home-manager
  ];
  
  # Enable nix flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  
  # Garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  
  # Users
  users.users.root.openssh.authorizedKeys.keys = [
    # Add your SSH public key here
  ];
  
  # ZFS services
  services.zfs = {
    autoScrub.enable = true;
    autoSnapshot.enable = false;  # Disable until data pool is configured
  };
  
  # System state version
  system.stateVersion = "24.11";
}
EOF

# Create hardware configuration with proper UUIDs
log "Detecting hardware configuration..."
EFI_UUID=$(blkid -s UUID -o value /dev/sde2)

cat > /etc/nixos/hardware-configuration.nix << EOF
# Hardware configuration for cottage
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ehci_pci" "ahci" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ "zfs" ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];
  
  # ZFS root
  fileSystems."/" = {
    device = "boot-pool/ROOT/nixos";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/${EFI_UUID}";
    fsType = "vfat";
  };

  swapDevices = [ ];
  
  # Enable ZFS
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.extraPools = [ "boot-pool" ];

  # Networking
  networking.useDHCP = lib.mkDefault true;
  
  # Platform
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  
  # CPU microcode
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  hardware.enableRedistributableFirmware = lib.mkDefault true;
  
  # Graphics support
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vaapiIntel
      vaapiVdpau
      libvdpau-va-gl
    ];
  };
}
EOF

# Step 3: Configure NIXOS_LUSTRATE to preserve important files
log "Configuring file preservation..."
cat > /etc/NIXOS_LUSTRATE << 'EOF'
etc/nixos
etc/resolv.conf
etc/ssh/ssh_host_*
var/lib/tailscale
root/.ssh
home
EOF

# Step 4: Create a marker file to indicate this is a cottage installation
echo "$HOST_NAME" > /etc/nixos/hostname

# Step 5: Run nixos-infect
log "Downloading and running nixos-infect..."
log "The system will reboot automatically when complete"
echo ""
warn "You may lose connection during the process"
warn "The system will be accessible via Tailscale after reboot"
echo ""

# Run nixos-infect
export NIX_CHANNEL="$NIXOS_CHANNEL"
export NIXOS_IMPORT=./hardware-configuration.nix

curl https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect | bash -x 2>&1 | tee /tmp/nixos-infect.log

# If we get here, something went wrong
error "nixos-infect did not reboot the system as expected"
error "Check /tmp/nixos-infect.log for details"
exit 1