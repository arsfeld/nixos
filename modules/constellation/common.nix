# Constellation common configuration module
#
# This module provides baseline configuration shared across all Constellation hosts.
# It establishes fundamental system settings, tools, and services that form the
# foundation of a functional NixOS system.
#
# Key features:
# - Nix flakes and experimental features configuration
# - Binary cache setup (nixos-community, numtide, deploy-rs, etc.)
# - Essential system packages and utilities
# - Network discovery via Avahi/mDNS
# - SSH and Tailscale for remote access
# - Automatic garbage collection
# - Common firewall and security settings
# - Hardware support and firmware
#
# This module is typically enabled on all hosts to ensure consistent base
# functionality across the infrastructure.
{
  inputs,
  config,
  pkgs,
  lib,
  ...
}:
with lib; {
  options.constellation.common = {
    enable = mkOption {
      type = types.bool;
      description = ''
        Enable common baseline configuration for Constellation hosts.
        This includes essential packages, services, and system settings.
      '';
      default = true;
    };
  };

  config = lib.mkIf config.constellation.common.enable {
    nix = {
      settings = {
        # Enable flakes and new 'nix' command
        experimental-features = "nix-command flakes";
        # Deduplicate and optimize nix store
        auto-optimise-store = true;

        # Enable substitutes for remote builders
        builders-use-substitutes = true;

        # Increase download buffer size to prevent "download buffer is full" warnings
        # Default is 64 MiB, increasing to 256 MiB
        download-buffer-size = 268435456; # 256 * 1024 * 1024
        substituters = lib.mkAfter [
          "https://harmonia.arsfeld.one"
          "https://harmonia.bat-boa.ts.net"
        ];
        trusted-public-keys = lib.mkAfter [
          "harmonia-raider-1:Cn74XNGOtXB2y3yHlU7uXoTpJqWA2p0l74Dcdwqt5aU="
        ];
      };

      # Configure remote builders (skip on cloud to avoid circular dependency)
      buildMachines = lib.optionals (config.networking.hostName != "cloud") [
        {
          hostName = "cloud.bat-boa.ts.net";
          system = "aarch64-linux";
          protocol = "ssh";
          sshUser = "root";
          maxJobs = 4;
          speedFactor = 2;
          supportedFeatures = ["nixos-test" "benchmark" "big-parallel"];
          mandatoryFeatures = [];
        }
      ];

      #registry.nixpkgs.flake = inputs.nixpkgs;

      # This will add each flake input as a registry
      # To make nix3 commands consistent with your flake
      registry = lib.mapAttrs (_: value: {flake = value;}) inputs;

      # This will additionally add your inputs to the system's legacy channels
      # Making legacy nix commands consistent as well, awesome!
      nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;
    };

    services.avahi = {
      enable = true;
      nssmdns4 = true; # Required for .local resolution via nsswitch
      publish = {
        enable = true;
        addresses = true;
        workstation = true;
        domain = true; # Optional: publishes domain info
        hinfo = true; # Optional: publishes hardware/OS details
      };
    };

    # Use standard Nix package (not Lix)
    # nix.package is automatically set to pkgs.nix by default

    security.polkit.enable = true;

    programs.fish.enable = true;

    # Configure SSH known hosts for remote builders
    programs.ssh.knownHosts = {
      "cloud.bat-boa.ts.net" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH51UBt4enqaDYdbEaBD1I1ef+wZGFmkjv68Mv4bnVWA";
      };
    };

    nix.settings.trusted-users = [
      "root"
      "@wheel"
    ];

    environment.systemPackages = with pkgs; [
      # From base profile
      w3m-nographics # needed for the manual anyway
      testdisk # useful for repairing boot problems
      ms-sys # for writing Microsoft boot sectors / MBRs
      efibootmgr
      efivar
      parted
      gptfdisk
      ddrescue
      ccrypt
      cryptsetup # needed for dm-crypt volumes

      # Some text editors.
      vim

      # Some networking tools.
      fuse
      fuse3
      sshfs-fuse
      socat
      screen
      tcpdump
      lsof
      iftop
      nmap
      dnsutils
      netcat
      mtr
      iproute2
      ethtool

      # System diagnostics and tracing
      iotop
      strace
      sysstat

      # Hardware-related tools.
      sdparm
      hdparm
      smartmontools # for diagnosing hard disks
      pciutils
      usbutils
      nvme-cli

      # Some compression/archiver tools.
      unzip
      zip

      # Add terminfo from ghostty
      ghostty

      binutils
      dosfstools
      duf
      exiftool
      ffmpeg
      file
      git
      gptfdisk
      htop
      home-manager
      keychain
      killall
      moreutils
      nano
      ncdu
      psmisc
      rclone
      tmux
      usbutils
      wget
      zpaq
    ];

    programs.nix-ld.enable = true;

    services.openssh.enable = true;
    nixpkgs.config.allowUnfree = true;
    time.timeZone = "America/Toronto";
    i18n.defaultLocale = "en_CA.UTF-8";
    zramSwap.enable = true;
    networking.nftables.enable = true;
    networking.firewall.allowedTCPPorts = [22];

    services.tailscale.enable = true;

    networking.firewall = {
      checkReversePath = "loose";
      trustedInterfaces = ["tailscale0"];
    };

    hardware.enableRedistributableFirmware = true;

    nix.gc = {
      automatic = true;
      dates = "Sat *-*-* 03:15:00";
      options = "--delete-older-than 30d";
    };

    system.stateVersion = lib.mkDefault "22.05";
  };
}
