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

  # Publisher credential for claude-notify (authenticated ntfy.arsfeld.one
  # publishes). owner + mode let the user-mode script read it directly.
  sops.secrets."ntfy-publisher-env" = {
    sopsFile = ../../secrets/sops/ntfy-client.yaml;
    owner = "arosenfeld";
    mode = "0400";
  };

  # Enable constellation modules
  constellation = {
    sops.enable = true;
    desktop = {
      enable = true;
      variant = "gnome";
      gnome.theme = {
        gtk = "Yaru-purple-dark";
        icon = "Yaru-purple";
      };
    };
    gaming = {
      enable = true;
      cpuVendor = "amd";
    };
    development.enable = true;
    virtualization.enable = true;
  };

  # Display scaling for high-DPI laptop screen.
  # sleep-inactive-*-type='nothing' works around gsd-power bug
  # https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/issues/903 (fixed in
  # gsd 50, not yet in nixpkgs). On NVIDIA-hybrid laptops the VT switch during
  # resume makes gsd-power store "sleep" as previous_idle_mode and re-suspend
  # ~15s after wake. Lid/power-button suspend still works via logind below.
  services.desktopManager.gnome.extraGSettingsOverrides = ''
    [org.gnome.desktop.interface]
    text-scaling-factor=1.25

    [org.gnome.settings-daemon.plugins.power]
    sleep-inactive-ac-type='nothing'
    sleep-inactive-battery-type='nothing'
  '';

  # Basic system configuration
  networking.hostName = "blackbird";

  # Ventoy bundles an older GTK3 flagged insecure by nixpkgs
  nixpkgs.config.permittedInsecurePackages = ["ventoy-gtk3-1.1.10"];

  # Additional packages
  environment.systemPackages = with pkgs; [
    powertop
    acpi # Battery status monitoring
    easyeffects # Audio enhancement for G14 speakers
    alsa-utils # Audio utilities
    librepods # Open-source AirPods client
    ventoy-full-gtk # Multiboot USB creator (CLI + GTK GUI, all plugins)
  ];

  # Bootloader: rEFInd as the boot menu (replaces systemd-boot). The rEFInd
  # NixOS module wipes anything in /boot/efi/refind/ that it didn't install,
  # so the previous manual install is cleanly superseded. dont_scan_dirs hides
  # the stale systemd-boot binary and orphan /EFI/nixos/*.efi kernels that the
  # old systemd-boot left behind on the ESP. use_nvram false keeps rEFInd's
  # own variables on the ESP instead of motherboard NVRAM.
  boot.loader.systemd-boot.enable = false;
  boot.loader.grub.enable = false;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.refind = {
    enable = true;
    extraConfig = ''
      use_nvram false
      dont_scan_dirs +,EFI/systemd,EFI/nixos,EFI/Microsoft/Recovery
    '';
  };
  services.refind-theme-regular = {
    enable = true;
    size = "medium";
    variant = "dark";
  };

  # Boot appearance
  boot.plymouth.enable = true;
  boot.plymouth.theme = "bgrt";
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;

  # Kernel parameters for performance and power management
  boot.kernelParams = [
    # Disable zswap - conflicts with zram (double compression wastes RAM)
    "zswap.enabled=0"
    "mitigations=off"
    "splash"
    "quiet"
    "udev.log_level=0"
    # i915 frame buffer + panel self-refresh: iGPU-only, safe for dGPU
    "i915.enable_fbc=1"
    "i915.enable_psr=2"
    "nmi_watchdog=0"
    # Use the active AMD P-state driver so power-profiles-daemon can steer
    # EPP directly. Without this the kernel falls back to acpi-cpufreq and PPD
    # only flips platform_profile, leaving CPU at a fixed governor.
    "amd_pstate=active"
    # Note: pcie_aspm=force + pcie_aspm.policy=powersupersave were removed -
    # they renegotiated the GTX 1660 Ti Max-Q link to PCIe 2.0 x8 and pinned
    # the dGPU in P5 / 30W TGP under load (Forza was VRAM-bandwidth starved).
    # TLP's PCIE_ASPM_ON_AC handles per-AC tuning instead.
  ];

  # NVIDIA PowerMizer: force highest performance level when the dGPU is in
  # use. Without this, the proprietary driver runs PowerMizer in adaptive
  # mode and refuses to leave P5 even at 97% utilization (memory clock stuck
  # at 810/6001 MHz under DXVK/Wine workloads on Wayland-Hybrid Optimus).
  # nvidia-settings/X11 GpuPowerMizerMode is unavailable on Wayland, so set
  # it via the kernel module's RegistryDwords. Dynamic Power Management is
  # left at its default (0x02) so the dGPU still suspends when unused.
  boot.extraModprobeConfig = ''
    options nvidia NVreg_RegistryDwords="PowerMizerEnable=0x1;PerfLevelSrc=0x3322;PowerMizerLevel=0x1;PowerMizerDefault=0x1;PowerMizerDefaultAC=0x1"
  '';

  # Run nvidia-persistenced so PowerMizer settings and any nvidia-smi -lgc
  # locks survive across application opens (Steam/Proton spawning Wine
  # processes otherwise tears the driver up/down).
  hardware.nvidia.nvidiaPersistenced = true;

  # Remove zfs support
  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs"];

  # ASUS G14 specific hardware support
  services.supergfxd.enable = true; # ASUS GPU switching
  services.asusd = {
    enable = true;
    enableUserService = true;
    fanCurvesConfig = {
      text = ''
        (
            profiles: (
                balanced: [
                    (
                        fan: CPU,
                        pwm: (0, 0, 0, 38, 89, 128, 191, 255),
                        temp: (30, 40, 50, 65, 75, 80, 90, 100),
                        enabled: true,
                    ),
                    (
                        fan: GPU,
                        pwm: (0, 0, 0, 26, 77, 115, 179, 255),
                        temp: (30, 40, 50, 65, 75, 80, 90, 100),
                        enabled: true,
                    ),
                ],
                performance: [],
                quiet: [],
                custom: [],
            ),
        )
      '';
    };
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
      cp ${./easyeffects-blackbird-preset.json} /home/arosenfeld/.config/easyeffects/output/ASUS_G14_2020.json
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

  # Power management - suspend then hibernate after delay
  systemd.sleep.extraConfig = ''
    HibernateDelaySec=30min
    SuspendState=mem
  '';

  # Fedora-on-ASUS power management: plain power-profiles-daemon (NOT
  # tuned-ppd). The asus-linux.org Fedora guide explicitly tells G14 owners to
  # `dnf swap tuned-ppd power-profiles-daemon` because tuned-ppd's tuned
  # profiles fight asusd over platform_profile, making the GNOME slider snap
  # back to Balanced within ~40ms. PPD writes platform_profile + amd_pstate
  # EPP directly (no tuned in the middle); asusd reacts via inotify to apply
  # the matching fan curve. Pairs with amd_pstate=active in kernelParams.
  services.power-profiles-daemon.enable = true;

  # Suspend then hibernate for lid/power button actions.
  # No IdleAction: logind counts suspend time as idle, and GNOME's own idle
  # suspend (gsd-power issue #903) misfires on NVIDIA-hybrid resume. Both
  # auto-idle paths are disabled; suspend is triggered only by lid or key.
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend-then-hibernate";
    HandleLidSwitchExternalPower = "suspend-then-hibernate";
    HandlePowerKey = "suspend-then-hibernate";
  };

  # NVIDIA + suspend-then-hibernate needs two pieces that NixOS doesn't wire
  # by default:
  #
  # 1. The NVIDIA driver ships a system-sleep hook (lib/systemd/system-sleep/
  #    nvidia) that handles the inner suspend->hibernate and post-resume
  #    transitions of suspend-then-hibernate by writing the right value to
  #    /proc/driver/nvidia/suspend based on $SYSTEMD_SLEEP_ACTION. NixOS's
  #    systemd.packages = [ nvidia_x11 ] only links systemd units, not
  #    system-sleep scripts, so install it explicitly.
  #
  # 2. The hook intentionally does NOT cover the initial pre:suspend phase,
  #    expecting nvidia-suspend.service to handle it. But systemd-suspend-
  #    then-hibernate.service doesn't pull in systemd-suspend.service, so
  #    nvidia-suspend.service never fires and the proprietary driver aborts
  #    the kernel suspend with EIO ("System Power Management attempted
  #    without driver procfs suspend interface"). Wire it explicitly. Do NOT
  #    add nvidia-hibernate.service here -- the inner hibernate transition
  #    is handled by the system-sleep hook above, and adding it caused both
  #    services to race and clobber each other's procfs writes.
  environment.etc."systemd/system-sleep/nvidia".source = "${config.hardware.nvidia.package.out}/lib/systemd/system-sleep/nvidia";

  systemd.services.nvidia-suspend = {
    before = ["systemd-suspend-then-hibernate.service"];
    requiredBy = ["systemd-suspend-then-hibernate.service"];
  };
  systemd.services.nvidia-resume = {
    after = ["systemd-suspend-then-hibernate.service"];
    requiredBy = ["systemd-suspend-then-hibernate.service"];
  };

  # On GA401IU, the keyboard backlight goes dark across suspend/hibernate
  # cycles -- writes to /sys/class/leds/asus::kbd_backlight/brightness keep
  # reporting the correct value but the LEDs themselves stop responding.
  # Rebinding the asus HID driver (the one that exposes the kbd_backlight
  # LED via HID feature reports) reinitializes the path and brings the
  # lights back. Run on post-sleep for any sleep action.
  environment.etc."systemd/system-sleep/asus-kbd-rebind".source = pkgs.writeShellScript "asus-kbd-rebind" ''
    case "$1" in
      post)
        for dev in /sys/bus/hid/drivers/asus/*0B05:1866*; do
          [ -L "$dev" ] || continue
          id=$(basename "$dev")
          echo "$id" > /sys/bus/hid/drivers/asus/unbind 2>/dev/null || true
          echo "$id" > /sys/bus/hid/drivers/asus/bind 2>/dev/null || true
        done
        ;;
    esac
  '';

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
