# Custom kexec image with Tailscale for nixos-anywhere
# This allows maintaining Tailscale connectivity during installation
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    # Base kexec installer
    (modulesPath + "/installer/netboot/netboot-minimal.nix")
  ];

  # Basic system configuration
  system.stateVersion = config.system.nixos.release;

  # Kernel configuration for kexec
  boot.kernelParams = [
    "panic=30"
    "boot.panic_on_fail"
    # Ensures the installer continues even if some operations fail
    "systemd.setenv=SYSTEMD_SULOGIN_FORCE=1"
    # Load to RAM for better performance
    "copytoram"
  ];

  # Enable SSH for installation
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      # Allow password auth temporarily for easier access
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = true;
    };
  };

  # Enable Tailscale
  services.tailscale = {
    enable = true;
    # Don't interfere with routing during installation
    interfaceName = "tailscale0";
  };

  # Networking
  networking = {
    # Use DHCP for all interfaces
    useDHCP = true;
    useNetworkd = true;
    # Don't block on network
    dhcpcd.wait = "background";

    # Firewall configuration
    firewall = {
      enable = true;
      allowedTCPPorts = [22]; # SSH
      trustedInterfaces = ["tailscale0"];
      # Allow Tailscale to work
      checkReversePath = "loose";
    };
  };

  # Essential packages for the installer
  environment.systemPackages = with pkgs; [
    # Basic tools
    vim
    tmux
    curl
    wget
    git

    # Disk tools
    parted
    gptfdisk
    cryptsetup

    # Filesystem tools
    e2fsprogs
    btrfs-progs
    xfsprogs
    zfs

    # Network tools
    iproute2
    iputils
    dnsutils

    # Tailscale CLI
    tailscale

    # For debugging
    htop
    iotop
    strace
  ];

  # Enable ZFS support
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.forceImportRoot = false;

  # Auto-login as root for easier access
  services.getty.autologinUser = lib.mkDefault "root";

  # Set a default root password (should be changed after kexec)
  users.users.root.initialPassword = "nixos";

  # System identification
  networking.hostName = "nixos-installer-tailscale";

  # Create a systemd service to restore Tailscale state if provided
  systemd.services.restore-tailscale-state = {
    description = "Restore Tailscale state from previous system";
    after = ["network.target"];
    before = ["tailscaled.service"];
    wantedBy = ["multi-user.target"];

    script = ''
      # Check if Tailscale state was preserved
      if [ -f /tmp/tailscale-state.tar.gz ]; then
        echo "Restoring Tailscale state..."
        mkdir -p /var/lib/tailscale
        tar -xzf /tmp/tailscale-state.tar.gz -C /
        echo "Tailscale state restored"
      else
        echo "No Tailscale state to restore"
      fi
    '';

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  # Add a helper script for Tailscale authentication
  environment.etc."nixos-anywhere-tailscale-setup.sh" = {
    mode = "0755";
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail

      echo "=== NixOS Anywhere Tailscale Setup ==="
      echo ""
      echo "This kexec installer includes Tailscale for maintaining connectivity."
      echo ""

      # Check if Tailscale is already authenticated
      if tailscale status &>/dev/null; then
        echo "✓ Tailscale is already connected!"
        tailscale status
      else
        echo "Tailscale is not connected. To authenticate:"
        echo "  1. Run: tailscale up"
        echo "  2. Visit the authentication URL"
        echo "  3. Once connected, you can continue the installation"
        echo ""
        echo "If you have a pre-auth key:"
        echo "  tailscale up --authkey=YOUR_KEY"
      fi

      echo ""
      echo "Once Tailscale is connected, run nixos-anywhere as usual."
    '';
  };

  # Show instructions on login
  services.getty.helpLine = ''

    === NixOS Installer with Tailscale ===
    Run '/etc/nixos-anywhere-tailscale-setup.sh' for Tailscale setup instructions.
  '';

  # Ensure the installer doesn't hang on shutdown
  systemd.services."systemd-poweroff".serviceConfig = {
    Type = lib.mkForce "exec";
  };

  # Build lighter image
  documentation.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;
}
