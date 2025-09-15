{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./disko-config.nix
  ];

  # Enable constellation modules
  constellation = {
    gnome = {
      enable = true;
      theme = {
        gtk = "Yaru-purple-dark";
        icon = "Yaru-purple";
      };
    };
    gaming.enable = true;
    development.enable = true;
    virtualization.enable = true;
  };

  # Display scaling configuration for GNOME
  services.xserver.desktopManager.gnome.extraGSettingsOverrides = ''
    [org.gnome.desktop.interface]
    text-scaling-factor=1.25

    [org.gnome.mutter]
    experimental-features=['scale-monitor-framebuffer']
  '';

  # Basic system configuration
  networking.hostName = "g14";

  # Additional packages
  environment.systemPackages = with pkgs; [
    powertop
    tlp # Advanced power management
    acpi # Battery status monitoring
    easyeffects # Audio enhancement for G14 speakers
    alsa-utils # Audio utilities
    librepods # Open-source AirPods client
  ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use Zen kernel for better desktop performance
  boot.kernelPackages = pkgs.linuxPackages_zen;

  # Boot appearance
  boot.plymouth.enable = true;
  boot.plymouth.theme = "bgrt";
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;

  # Kernel parameters for performance and power management
  boot.kernelParams = [
    # Configure zswap for better performance
    "zswap.enabled=1"
    "zswap.compressor=zstd"
    "zswap.max_pool_percent=25"
    "zswap.zpool=z3fold"
    "mitigations=off"
    "splash"
    "quiet"
    "udev.log_level=0"
    # Additional power saving parameters
    "pcie_aspm=force"
    "pcie_aspm.policy=powersupersave"
    "i915.enable_fbc=1"
    "i915.enable_psr=2"
    "nmi_watchdog=0"
  ];

  # Memory management settings to prevent swap thrashing
  boot.kernel.sysctl = {
    # Reduce swappiness - only swap when really necessary (default is 60)
    "vm.swappiness" = 10;
    # Don't swap out pages unless memory pressure is high
    "vm.vfs_cache_pressure" = 50;
    # Prefer to reclaim page cache over swap
    "vm.dirty_ratio" = 15;
    "vm.dirty_background_ratio" = 5;
  };

  # Remove zfs support
  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs" "bcachefs"];

  # ASUS G14 specific hardware support
  services.supergfxd.enable = true; # ASUS GPU switching
  services.asusd = {
    enable = true;
    enableUserService = true;
  };

  # Audio enhancements for G14 speakers
  # EasyEffects will be configured in home-manager with G14-specific presets
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Setup EasyEffects preset for G14 speakers
  system.activationScripts.setupEasyEffectsG14 = ''
    # Create EasyEffects config directory if it doesn't exist
    mkdir -p /home/arosenfeld/.config/easyeffects/output
    mkdir -p /home/arosenfeld/.config/easyeffects/autoload/output

    # Install the ASUS G14 preset (from RaduTek's EasyEffects-Presets)
    if [ ! -f /home/arosenfeld/.config/easyeffects/output/ASUS_G14_2020.json ]; then
      cp ${./easyeffects-g14-preset.json} /home/arosenfeld/.config/easyeffects/output/ASUS_G14_2020.json
      chown arosenfeld:users /home/arosenfeld/.config/easyeffects/output/ASUS_G14_2020.json
    fi

    # Create autoload symlink to automatically load the preset
    if [ ! -L /home/arosenfeld/.config/easyeffects/autoload/output/ASUS_G14_2020.json ]; then
      ln -sf /home/arosenfeld/.config/easyeffects/output/ASUS_G14_2020.json \
             /home/arosenfeld/.config/easyeffects/autoload/output/ASUS_G14_2020.json
      chown -h arosenfeld:users /home/arosenfeld/.config/easyeffects/autoload/output/ASUS_G14_2020.json
    fi

    # Create EasyEffects settings file to enable autoload
    if [ ! -f /home/arosenfeld/.config/easyeffects/settings.json ]; then
      cat > /home/arosenfeld/.config/easyeffects/settings.json << 'EOF'
    {
      "settings": {
        "bypass": false,
        "output-device": "default",
        "use-dark-theme": true,
        "process-all-outputs": true,
        "process-all-inputs": false,
        "autohide-window": false,
        "reset-volume": false,
        "window-height": 600,
        "window-width": 800,
        "autostart": true,
        "priority-type": "niceness",
        "niceness": -10,
        "realtime-priority": 5
      }
    }
    EOF
      chown arosenfeld:users /home/arosenfeld/.config/easyeffects/settings.json
    fi
  '';

  # Auto-start EasyEffects as a user service
  # Note: Preset autoloading works through the autoload symlink created above
  # The user may need to manually select the preset once in the GUI for it to persist
  systemd.user.services.easyeffects = {
    description = "EasyEffects Audio Enhancement";
    wantedBy = ["graphical-session.target"];
    partOf = ["graphical-session.target"];
    after = ["graphical-session.target" "pipewire.service"];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.easyeffects}/bin/easyeffects --gapplication-service";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Networking configuration
  networking.nftables.enable = true;

  # Use NetworkManager for network management (better for laptops)
  networking.networkmanager.enable = true;
  networking.useDHCP = false;

  # Add user to networkmanager group for network management
  users.users.arosenfeld.extraGroups = ["networkmanager"];

  # Disable wait-online service to speed up boot
  systemd.services.NetworkManager-wait-online.enable = false;

  # Incus container management (in addition to libvirt from constellation.virtualization)
  virtualisation.incus = {
    enable = true;
    ui.enable = true;
  };

  # Power management - enable hybrid sleep
  systemd.sleep.extraConfig = ''
    HibernateDelaySec=60min
    SuspendState=mem
    HibernateState=disk
    HybridSleepState=disk
    HybridSleepMode=suspend platform shutdown
  '';

  # Advanced Power Management with TLP
  services.tlp = {
    enable = true;
    settings = {
      # CPU power management - balanced for both AC and battery
      CPU_SCALING_GOVERNOR_ON_AC = "schedutil"; # More balanced, less aggressive
      CPU_SCALING_GOVERNOR_ON_BAT = "schedutil"; # More balanced than powersave
      CPU_ENERGY_PERF_POLICY_ON_AC = "balance_performance"; # Quieter operation on AC
      CPU_ENERGY_PERF_POLICY_ON_BAT = "balance_performance"; # Better balance
      CPU_MIN_PERF_ON_AC = 0;
      CPU_MAX_PERF_ON_AC = 100;
      CPU_MIN_PERF_ON_BAT = 20; # Higher minimum for better responsiveness
      CPU_MAX_PERF_ON_BAT = 100; # Full performance available when needed
      CPU_BOOST_ON_AC = 0; # Disable boost on AC for quieter operation
      CPU_BOOST_ON_BAT = 0; # Keep boost disabled on battery for better efficiency

      # Platform profiles
      PLATFORM_PROFILE_ON_AC = "balanced"; # Balanced for quieter operation
      PLATFORM_PROFILE_ON_BAT = "balanced"; # Changed from low-power to balanced

      # Disk power management
      DISK_IDLE_SECS_ON_AC = 0;
      DISK_IDLE_SECS_ON_BAT = 2;
      DISK_APM_LEVEL_ON_AC = "254 254";
      DISK_APM_LEVEL_ON_BAT = "128 128";

      # PCIe power management
      RUNTIME_PM_ON_AC = "auto";
      RUNTIME_PM_ON_BAT = "auto";
      PCIE_ASPM_ON_AC = "default";
      PCIE_ASPM_ON_BAT = "powersupersave";

      # USB autosuspend
      USB_AUTOSUSPEND = 1;
      USB_EXCLUDE_PHONE = 1;

      # WiFi power saving
      WIFI_PWR_ON_AC = "off";
      WIFI_PWR_ON_BAT = "on";

      # Sound power management
      SOUND_POWER_SAVE_ON_AC = 0;
      SOUND_POWER_SAVE_ON_BAT = 1;
      SOUND_POWER_SAVE_CONTROLLER = "Y";

      # Battery charge thresholds disabled for full charging
    };
  };

  # Auto-cpufreq as alternative/addition to TLP (comment out if conflicts arise)
  services.auto-cpufreq = {
    enable = false; # Set to true if you prefer this over TLP's CPU management
    settings = {
      battery = {
        governor = "powersave";
        turbo = "never";
      };
      charger = {
        governor = "performance";
        turbo = "auto";
      };
    };
  };

  # Thermald for thermal management
  services.thermald.enable = true;

  # Power profiles daemon (works with GNOME)
  services.power-profiles-daemon.enable = false; # Disabled as TLP handles this

  # Enable hybrid-sleep target for power button and lid actions
  services.logind = {
    lidSwitch = lib.mkForce "hybrid-sleep";
    lidSwitchExternalPower = lib.mkForce "hybrid-sleep";
    extraConfig = lib.mkForce ''
      HandlePowerKey=hybrid-sleep
      IdleAction=hybrid-sleep
      IdleActionSec=30min
    '';
  };

  # Set your time zone
  time.timeZone = "America/Toronto";

  # Select internationalisation properties
  i18n.defaultLocale = "en_CA.UTF-8";

  # Configure keymap in X11
  services.xserver = {
    xkb.layout = "us";
    xkb.variant = "alt-intl";
  };

  # Configure console keymap
  console.keyMap = "us";

  # Enable the OpenSSH daemon
  services.openssh.enable = true;

  # Disable firewall for development
  networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  system.stateVersion = "23.11";
}
