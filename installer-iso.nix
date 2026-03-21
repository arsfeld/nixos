# Custom NixOS installer ISO with disko and automated install support
# Build with: nix build .#installer-iso
# Flash with: dd if=result/iso/nixos-*.iso of=/dev/sdX bs=4M status=progress conv=fsync
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
  ];

  # System identification
  system.stateVersion = config.system.nixos.release;
  networking.hostName = "nixos-installer";
  isoImage.isoName = lib.mkForce "nixos-installer-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}.iso";
  isoImage.volumeID = lib.mkForce "NIXOS_INSTALLER";

  # WiFi firmware
  hardware.enableRedistributableFirmware = true;

  # SSH access with pre-configured keys for headless operation
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
  ];
  users.users.nixos.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w"
  ];

  # Essential packages for installation
  environment.systemPackages = with pkgs; [
    btrfs-progs
    parted
    gptfdisk
    cryptsetup
    dosfstools
    e2fsprogs
    vim
    tmux
    htop
    curl
    wget
    git
  ];

  # Disable ZFS to avoid kernel module build (G14 uses btrfs)
  boot.supportedFilesystems = lib.mkForce ["btrfs" "vfat" "f2fs" "xfs" "ntfs" "cifs"];

  # Smaller ISO
  documentation.enable = lib.mkOverride 400 false;
  documentation.doc.enable = lib.mkOverride 400 false;
  documentation.nixos.enable = lib.mkOverride 400 false;

  # Install helper script
  environment.etc."install-nixos.sh" = {
    mode = "0755";
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail

      HOSTNAME="''${1:-g14}"
      REPO_URL="https://github.com/arsfeld/nixos.git"
      REPO_DIR="/tmp/nixos-config"

      echo "=== NixOS Installer ==="
      echo ""
      echo "Target host: $HOSTNAME"
      echo ""

      # Step 1: Check network connectivity
      echo "[1/4] Checking network connectivity..."
      if ! ping -c1 -W5 github.com &>/dev/null; then
        echo ""
        echo "ERROR: No network connectivity."
        echo ""
        echo "Connect to WiFi first:"
        echo "  nmtui                                              # interactive TUI"
        echo "  nmcli device wifi connect SSID password PASSWORD   # command line"
        echo ""
        echo "Then re-run this script."
        exit 1
      fi
      echo "  Network OK."

      # Step 2: Clone the configuration repo
      echo "[2/4] Cloning configuration repository..."
      if [ -d "$REPO_DIR" ]; then
        echo "  Updating existing clone..."
        git -C "$REPO_DIR" pull --ff-only
      else
        git clone "$REPO_URL" "$REPO_DIR"
      fi

      # Verify host configuration exists
      if [ ! -f "$REPO_DIR/hosts/$HOSTNAME/configuration.nix" ]; then
        echo "ERROR: No configuration found for host '$HOSTNAME'"
        echo "Available hosts:"
        for d in "$REPO_DIR"/hosts/*/; do
          [ -f "$d/configuration.nix" ] && echo "  - $(basename "$d")"
        done
        exit 1
      fi
      echo "  Host configuration found: $HOSTNAME"

      # Step 3: Run disko to partition and format
      echo "[3/4] Partitioning and formatting disks with disko..."
      echo ""
      echo "WARNING: This will DESTROY ALL DATA on the target disk(s)!"
      echo ""

      if [ -f "$REPO_DIR/hosts/$HOSTNAME/disko-config.nix" ]; then
        echo "Disk configuration:"
        grep 'device = ' "$REPO_DIR/hosts/$HOSTNAME/disko-config.nix" | sed 's/^/  /'
      fi
      echo ""

      read -p "Continue with disk formatting? (y/N) " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
      fi

      nix run github:nix-community/disko -- \
        --mode destroy,format,mount \
        --yes-wipe-all-disks \
        "$REPO_DIR/hosts/$HOSTNAME/disko-config.nix"

      echo "  Disks partitioned and mounted at /mnt."

      # Step 4: Install NixOS
      echo "[4/4] Installing NixOS configuration '$HOSTNAME'..."
      nixos-install --flake "$REPO_DIR#$HOSTNAME" --no-root-password

      echo ""
      echo "=== Installation complete! ==="
      echo ""
      echo "Next steps:"
      echo "  1. reboot"
      echo "  2. Remove the USB drive"
      echo "  3. Run 'tailscale up' for Tailscale access"
    '';
  };

  # Show instructions on login
  services.getty.helpLine = lib.mkForce ''

    === NixOS Custom Installer ===

    1. Connect to WiFi:  nmtui  (or: nmcli device wifi connect SSID password PASSWORD)
    2. Run installer:    sudo /etc/install-nixos.sh [hostname]
                         (default hostname: g14)

    SSH is enabled. The "nixos" and "root" accounts have empty passwords.
  '';
}
