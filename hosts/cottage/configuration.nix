{
  lib,
  pkgs,
  config,
  self,
  inputs,
  ...
}:
with lib; {
  imports = [
    ./hardware-configuration.nix
    ./disko-config.nix
    ./services
    ./backup
  ];

  # Enable all constellation modules
  constellation = {
    backup.enable = true;
    common.enable = true;
    email.enable = true;
    media.enable = true;
    podman.enable = true;
    services.enable = true;
    virtualization.enable = true;
  };

  # Enable media services with cottage-specific domain
  media.config = {
    enable = true;
    domain = "arsfeld.com";
  };

  # Host-specific settings
  networking = {
    hostName = "cottage";
    hostId = "d4c0ffee"; # Required for ZFS
    
    # Use DHCP as fallback on all interfaces
    useDHCP = true;
    
    # Ensure network doesn't block boot
    dhcpcd = {
      wait = "background"; # Don't wait for DHCP during boot
      extraConfig = ''
        # Shorter timeout for faster boot
        timeout 10
        # Don't wait for IPv6
        noipv6rs
        # Continue even without lease
        fallback
      '';
    };
  };
  
  # Emergency SSH access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes"; # Allow root login for emergency access
      PasswordAuthentication = false;
    };
    # Start SSH early in boot process
    startWhenNeeded = false;
  };
  
  # Ensure SSH starts even if network is degraded
  systemd.services.sshd = {
    wantedBy = [ "multi-user.target" ];
    after = lib.mkForce [ "network.target" ];
  };
  
  nixpkgs.hostPlatform = "x86_64-linux";

  # Bootloader configuration
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Kernel settings
  boot = {
    binfmt.emulatedSystems = [ "aarch64-linux" ];
    kernelModules = [ "kvm-intel" "ip6_tables" ];
    supportedFilesystems = [ "zfs" ];
    
    # ZFS boot resilience
    zfs = {
      forceImportRoot = false; # Don't force import root pool
      forceImportAll = false; # Don't force import other pools
      allowHibernation = false; # Disable hibernation for ZFS stability
    };
    
    # Allow booting with degraded ZFS pools
    kernelParams = [ 
      "zfs.zfs_scan_vdev_limit=16M" # Limit resilver speed to prevent overload
      "nohibernate" # Disable hibernation
    ];
    
    # ZFS import configuration - allow degraded imports
    initrd.systemd.services."zfs-import-degraded" = {
      description = "Import ZFS pools with degraded support";
      after = [ "zfs-import.target" ];
      before = [ "zfs.target" ];
      wantedBy = [ "zfs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = ''
          ${pkgs.runtimeShell} -c '
            # Try normal import first
            if ! ${pkgs.zfs}/bin/zpool import -a -N 2>/dev/null; then
              echo "Normal ZFS import failed, trying degraded import..."
              ${pkgs.zfs}/bin/zpool import -a -N -f -d /dev/disk/by-id 2>/dev/null || true
            fi
          '
        '';
      };
    };
  };

  # Early OOM killer
  services.earlyoom.enable = true;

  # Use latest kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Disable network wait online service
  systemd.services.NetworkManager-wait-online.enable = false;

  # Caddy configuration for SSL certificates
  users.users.caddy.extraGroups = [ "acme" ];

  security.acme = {
    acceptTerms = true;
  };

  services.caddy = {
    enable = true;
  };

  services.tailscale.permitCertUid = "caddy";

  # Systemd boot resilience
  systemd = {
    # Allow boot to continue even if some units fail
    enableEmergencyMode = false; # Don't drop to emergency shell
  };

  # SMART monitoring
  services.smartd = {
    enable = true;
    notifications.mail.enable = true;
    notifications.test = true;
  };

  # Avahi for service discovery
  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      userServices = true;
    };
  };

  # GPG agent configuration
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = false;
    pinentryPackage = pkgs.pinentry-tty;
  };

  # Graphics support for hardware acceleration
  nixpkgs.config.packageOverrides = pkgs: {
    vaapiIntel = pkgs.vaapiIntel.override { enableHybridCodec = true; };
  };

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      vaapiIntel
      vaapiVdpau
      libvdpau-va-gl
      intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
      vpl-gpu-rt
    ];
  };

  # Allow insecure packages (if needed)
  nixpkgs.config.permittedInsecurePackages = [
    "aspnetcore-runtime-6.0.36"
    "aspnetcore-runtime-wrapped-6.0.36"
    "dotnet-sdk-6.0.428"
    "dotnet-sdk-wrapped-6.0.428"
  ];

  # Ensure boot continues even if filesystems fail
  boot.initrd.systemd.enable = true;
  boot.initrd.systemd.emergencyAccess = true;
  
  # System state version
  system.stateVersion = "25.05";
}