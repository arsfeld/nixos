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
    (modulesPath + "/installer/cd-dvd/installation-cd-graphical-gnome.nix")
  ];

  # Enable flakes so nixos-install --flake works
  nix.settings.experimental-features = ["nix-command" "flakes"];

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

      # Re-exec as root if not already
      if [ "$(id -u)" -ne 0 ]; then
        exec sudo NIX_CONFIG="experimental-features = nix-command flakes" "$0" "$@"
      fi

      export NIX_CONFIG="experimental-features = nix-command flakes"

      REPO_URL="https://github.com/arsfeld/nixos.git"
      REPO_DIR="/tmp/nixos-config"
      REMOTE_SCRIPT="$REPO_DIR/scripts/install-nixos.sh"

      # Step 1: Check network connectivity
      echo "[1/2] Checking network connectivity..."
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

      # Step 2: Fetch latest installer from repo
      echo "[2/2] Fetching latest installer from repository..."
      if [ -d "$REPO_DIR" ]; then
        git -C "$REPO_DIR" pull --ff-only
      else
        git clone "$REPO_URL" "$REPO_DIR"
      fi

      # Hand off to the repo's install script
      exec bash "$REMOTE_SCRIPT" "$@"
    '';
  };

  # Show instructions on login
  services.getty.helpLine = lib.mkForce ''

    === NixOS Custom Installer ===

    1. Connect to WiFi:  nmtui  (or: nmcli device wifi connect SSID password PASSWORD)
    2. Run installer:    /etc/install-nixos.sh [hostname]
                         (default hostname: g14, fetches latest from git)

    SSH is enabled. The "nixos" and "root" accounts have empty passwords.
  '';
}
