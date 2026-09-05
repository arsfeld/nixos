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
      gnome.monitorControl.enable = true;
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
  nixpkgs.config.permittedInsecurePackages = ["ventoy-gtk3-1.1.12"];

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
    # Note: pcie_aspm=force + pcie_aspm.policy=powersupersave were removed so
    # TLP's PCIE_ASPM_ON_AC can do per-AC tuning instead. Removing them did
    # NOT fix the dGPU's P5 / 30 W lock, which the old comment here claimed:
    # ASPM now reads Disabled on both link ends and the link still trains at
    # Gen 2 x8. See hardware-configuration.nix for the measured ceiling.
  ];

  # Run nvidia-persistenced so the driver stays initialised across application
  # opens — Steam/Proton spawning Wine processes otherwise tears it up and down
  # repeatedly. (It does not help the clock lock; nothing does. See the dGPU
  # power ceiling note in hardware-configuration.nix.)
  hardware.nvidia.nvidiaPersistenced = true;

  # Remove zfs support
  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs"];

  # ASUS G14 specific hardware support
  services.supergfxd.enable = true; # ASUS GPU switching
  services.asusd = {
    enable = true;
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

  home-manager.users.arosenfeld.xdg.dataFile = {
    "easyeffects/output/ASUS_G14_2020.json".source = ./easyeffects-blackbird-preset.json;
    "easyeffects/output/No_Effects.json".source = ./easyeffects-no-effects-preset.json;

    "easyeffects/autoload/output/alsa_output.pci-0000_04_00.6.analog-stereo:Speakers.json".text = builtins.toJSON {
      device = "alsa_output.pci-0000_04_00.6.analog-stereo";
      "device-description" = "Ryzen HD Audio Controller Analog Stereo";
      "device-profile" = "Speakers";
      "preset-name" = "ASUS_G14_2020";
    };

    "easyeffects/autoload/output/alsa_output.pci-0000_01_00.1.hdmi-stereo:HDMI _ DisplayPort.json".text = builtins.toJSON {
      device = "alsa_output.pci-0000_01_00.1.hdmi-stereo";
      "device-description" = "TU116 High Definition Audio Controller Digital Stereo (HDMI)";
      "device-profile" = "HDMI / DisplayPort";
      "preset-name" = "No_Effects";
    };
  };

  # Remove only the obsolete, root-owned EasyEffects files created by older
  # versions of this configuration. Preserve the settings database and any
  # unrelated user files.
  system.activationScripts.easyeffectsLegacyCleanup.text = ''
    ${pkgs.coreutils}/bin/rm -f \
      /home/arosenfeld/.config/easyeffects/autoload/output/ASUS_G14_2020.json \
      /home/arosenfeld/.config/easyeffects/output/ASUS_G14_2020.json \
      /home/arosenfeld/.config/easyeffects/settings.json

    ${pkgs.coreutils}/bin/rmdir --ignore-fail-on-non-empty \
      /home/arosenfeld/.config/easyeffects/autoload/output \
      /home/arosenfeld/.config/easyeffects/autoload \
      /home/arosenfeld/.config/easyeffects/output \
      /home/arosenfeld/.config/easyeffects 2>/dev/null || true
  '';

  # Auto-start EasyEffects as a user service
  systemd.user.services.easyeffects = {
    description = "EasyEffects Audio Enhancement";
    wantedBy = ["graphical-session.target"];
    partOf = ["graphical-session.target"];
    after = ["graphical-session.target" "pipewire.service" "wireplumber.service"];
    wants = ["pipewire.service" "wireplumber.service"];
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

  # Fedora-on-ASUS power management: plain power-profiles-daemon (NOT
  # tuned-ppd). The asus-linux.org Fedora guide explicitly tells G14 owners to
  # `dnf swap tuned-ppd power-profiles-daemon` because tuned-ppd's tuned
  # profiles fight asusd over platform_profile, making the GNOME slider snap
  # back to Balanced within ~40ms. PPD writes platform_profile + amd_pstate
  # EPP directly (no tuned in the middle); asusd reacts via inotify to apply
  # the matching fan curve. Pairs with amd_pstate=active in kernelParams.
  services.power-profiles-daemon.enable = true;

  # Plain S3 suspend for lid close and power key -- deliberately NOT
  # suspend-then-hibernate. Two reasons: (1) the 16 GiB swap is smaller than
  # RAM (22 GiB), so hibernate could fail under memory pressure; (2) s2h on
  # NVIDIA Optimus is unreliable upstream (the inner suspend->hibernate
  # transition often doesn't drive the nvidia path). Plain suspend is the
  # rock-solid option and a laptop is rarely off long enough for hibernate to
  # matter.
  #
  # No IdleAction: GNOME's gsd-power idle suspend (nixpkgs#336723) misfires on
  # NVIDIA-hybrid resume, so both auto-idle paths stay disabled; suspend is
  # triggered only by lid or power key via logind.
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "suspend";
    HandlePowerKey = "suspend";
  };

  # NVIDIA suspend/resume: nothing to wire. kernelSuspendNotifier defaults to
  # `open && version >= 595`, both true here, so the driver saves and restores
  # video memory through the kernel suspend notifier and nixpkgs deliberately
  # does NOT install nvidia-suspend/-resume/-hibernate or the
  # /lib/systemd/system-sleep/nvidia hook. `powerManagement.enable = true`
  # (hardware-configuration.nix) is the entire supported config.
  #
  # Do NOT hand-declare systemd.services.nvidia-suspend/-resume here: in
  # notifier mode nixpkgs provides no ExecStart to merge with, so the unit ends
  # up empty (LoadState=bad-setting) and, being requiredBy the suspend job,
  # aborts every suspend with an immediate resume. That was the bug this
  # replaced. Note this flips with `open`: under the closed modules nixpkgs
  # ships those units itself, and declaring them would collide instead.

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

  # Goodix 27c6:521d (built-in fingerprint reader) is on libfprint's
  # known-unsupported list, so fprintd is pointed at
  # pkgs.libfprint-goodix-521d, a fork carrying the community goodixtls
  # driver patched to accept this sensor's firmware. fprintd takes libfprint
  # as an overridable argument, which keeps the fork scoped to this host
  # instead of overlaying libfprint globally (the overlay in
  # flake-modules/lib.nix would otherwise drag all nine hosts onto a
  # five-year-old libfprint fork).
  services.fprintd = {
    enable = true;
    package = pkgs.fprintd.override {
      libfprint = pkgs.libfprint-goodix-521d;
    };
  };

  # Disable firewall for development
  networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  system.stateVersion = "23.11";
}
