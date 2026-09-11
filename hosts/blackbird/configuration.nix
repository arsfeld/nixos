{
  config,
  pkgs,
  lib,
  ...
}: let
  # Astra Monitor addresses GPUs by the PCI fields it parses out of `lspci -nnk`
  # and compares domain/bus/slot/vendorId/productId. For the dGPU at 01:00.0
  # [10de:2191] that is domain "0000:01", bus "00", slot "0" -- its field names
  # are shifted one place from the usual domain:bus:device.function.
  dgpu = {
    domain = "0000:01";
    bus = "00";
    slot = "0";
    vendorId = "10de";
    productId = "2191";
  };

  # The dGPU's enforced power limit in the top bar: the number the
  # nvidia-unclamp-tgp unit below exists to change, and which has been seen
  # reverting to 30 W mid-session. Printed for gnomeExtensions.executor, which
  # runs it through `bash -c` on an interval.
  #
  # `nvidia-smi --query-gpu=power.limit` returns [N/A] on this GPU (measured on
  # driver 595.71.05), so the limits have to come from the -q report, where they
  # are populated. There "Current Power Limit" appears twice -- under GPU Power
  # Readings and again under Module Power Readings, which is all N/A here -- so
  # awk windows on the first block rather than grepping. P-state, memory clock
  # and the SW Power Cap flag do work through --query-gpu.
  dgpu-power = pkgs.writeShellScriptBin "dgpu-power" ''
    smi=${config.hardware.nvidia.package.bin}/bin/nvidia-smi

    limits=$("$smi" -q -d POWER 2>/dev/null | awk '
      /GPU Power Readings/    { gpu = 1 }
      /Module Power Readings/ { gpu = 0 }
      gpu && /Current Power Limit/ { cur = $(NF - 1) }
      gpu && /Default Power Limit/ { print cur, $(NF - 1); exit }
    ')
    read -r cur def <<<"$limits"
    # Driver not loaded, or the fields read N/A: print nothing, not noise.
    case "$cur$def" in "" | *[!0-9.]*) exit 0 ;; esac

    IFS=, read -r pstate mem cap <<<"$(
      "$smi" --query-gpu=pstate,clocks.mem,clocks_event_reasons.sw_power_cap \
             --format=csv,noheader,nounits 2>/dev/null | tr -d ' '
    )"

    cap_flag=""
    [ "$cap" = Active ] && cap_flag=" cap"

    if [ "$cur" = "$def" ]; then
      printf '%.0fW %s %sMHz%s\n' "$cur" "$pstate" "$mem" "$cap_flag"
    else
      printf '! %.0f/%.0fW %s %sMHz%s\n' "$cur" "$def" "$pstate" "$mem" "$cap_flag"
    fi
  '';
in {
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
      gnome.gpuMonitor.enable = true;
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
    dgpu-power # dGPU power-limit readout, also driven by Executor below
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

  # constellation.gaming pins every gaming host to linuxPackages_xanmod_latest
  # (lib.mkOverride 990). The 2026-09-10 flake update carried that build to Linux
  # 7.2, whose headers no longer transitively include <string.h>, and the
  # nvidia-open kernel module fails to compile against it:
  #   os-interface.c:764: implicit declaration of function 'strncpy'
  # The driver is nvidiaPackages.stable (595.71.05), pulled through
  # config.boot.kernelPackages by hardware-configuration.nix. This host's entire
  # dGPU 30 W-clamp workaround (nvidia-unclamp-tgp, dgpu-power) is calibrated
  # against 595.71.05, so hold the driver and step the kernel back to XanMod's
  # LTS branch, which nvidia-open 595 still builds against. lib.mkForce beats the
  # gaming module's 990. Drop this once nixpkgs' nvidia stable carries the fix.
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_xanmod;

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

  # nvidia-persistenced stays off. It is a headless-compute tool -- it keeps the
  # driver from deinitialising between CUDA jobs -- and nothing here needs that.
  # gnome-shell holds /dev/nvidia0 for the whole session anyway, so the driver
  # teardown its old comment worried about cannot happen.
  #
  # It was briefly switched back on under the theory that it PINS whatever power
  # budget exists when it starts, and so would hold the 60 W that
  # nvidia-unclamp-tgp establishes. That theory is falsified: with persistence
  # mode off, 60 W held across an idle GPU, an opened+closed Vulkan context, an
  # opened+closed OpenCL context, display-manager starting and gnome-shell
  # taking the device, and a full gamemode activation.
  #
  # Nor is it the cause of the clamp: booted with it false and the unclamp unit
  # masked, and the dGPU still came up at 30 W.
  hardware.nvidia.nvidiaPersistenced = false;

  # The dGPU comes up clamped to 30 W -- half its own 60 W VBIOS default, and
  # well under the 65 W this chassis is rated for with ROG Boost. Under that
  # clamp the driver holds perf level 1 of 3, which pins memory to 810 MHz
  # against a 6001 MHz spec. Measured effect: 26.2 GB/s of a ~288 GB/s bus, and
  # SW Power Cap active continuously in-game while the core sheds clock to fit.
  #
  # Reloading the nvidia modules once clears it. Measured immediately after,
  # same machine, same session: 60 W enforced, 6001 MHz memory, P0, and clpeak
  # global memory bandwidth 243 GB/s -- a 9.3x improvement, and ~85% of
  # theoretical, which is normal efficiency.
  #
  # Two things NOT to re-derive:
  #   - The NVRM "PlatformRequestHandler failed to get target temp / platform
  #     power mode from SBIOS" errors fire on the boot load AND on this reload,
  #     which succeeds. So they are correlated, not causal. Do not chase them
  #     expecting the clamp to move. (Cause: this board has no NVPCF at all and
  #     its legacy ACPI GPS handler is a stub -- CTGP, the Configurable-TGP
  #     grant, is never assigned anywhere in the DSDT or any of the 10 SSDTs.)
  #   - nvidia-smi -pl / -lmc are refused by the driver on this consumer mobile
  #     part, and GPUPowerMizerMode reads back 0 after being set. Neither is a
  #     lever here; the module reload is.
  #
  # Isolated by experiment -- the reload itself is the operative step, so do not
  # "simplify" this into a settings tweak:
  #   - Not nvidiaPersistenced. Booted with it false and this unit masked: still
  #     30 W. It is off, and not needed to hold the result either.
  #   - Not lact. Its config carries no power cap (current_profile: null), and
  #     60 W survives lactd restarting.
  #   - Not supergfxd. It starts at ~10.2 s, after the driver initialised at
  #     8.6 s and after the SBIOS errors at 9.8 s, so it is downstream of the
  #     clamp. (It does set the dGPU's runtime PM to Auto and tries to start
  #     nvidia-powerd, which fails -- expected, this board has no NVPCF.)
  #   - Not a warm-up effect. The reload was measured working at 52 s uptime.
  #
  # KNOWN LIMITATION -- this unit is not the whole fix. The 60 W it establishes
  # at boot has been observed reverting to 30 W later in a session: one boot ran
  # the unit at 12 s and read 60 W at 26 s, then Steam started at 62 s and Forza
  # at 105 s, and by ~200 s the dGPU was back to 30 W with SW Power Cap active,
  # where it stayed for the whole play session.
  #
  # The trigger is NOT known. Falsified by measurement, each with 60 W holding:
  # an idle GPU for minutes, an opened+closed Vulkan context, an opened+closed
  # OpenCL context, display-manager starting and gnome-shell taking the device,
  # and a gamemode activation (which was the best suspect, since gaming.nix sets
  # apply_gpu_optimisations + nv_powermizer_mode=1 against card0, and card0 is
  # the NVIDIA GPU here). The untested difference is Steam's pressure-vessel
  # runtime, or sustained real game load.
  #
  # Likely relevant, and the best lead for why this hardware behaves this way at
  # all: the nvidia module initialises at 8.160 s and asus-nb-wmi only registers
  # platform_profile support at 8.251 s. The GPU driver comes up 91 ms before
  # the ASUS platform interface exists.
  #
  # Ordered before display-manager so GDM has not taken the device yet. The
  # lactd stop is defensive: LACT is disabled in constellation.gaming now, but
  # it held /dev/nvidia* and would block the rmmod if it ever comes back.
  # Every step is fail-soft: a failure here must never block boot.
  systemd.services.nvidia-unclamp-tgp = {
    description = "Reload NVIDIA modules to clear the boot-time 30 W dGPU clamp";
    wantedBy = ["display-manager.service"];
    before = ["display-manager.service"];
    after = ["systemd-udev-settle.service"];
    unitConfig.ConditionPathExists = "/dev/nvidia0";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set +e
      systemctl stop lactd 2>/dev/null
      for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
        ${pkgs.kmod}/bin/modprobe -r "$m" 2>/dev/null
      done
      ${pkgs.kmod}/bin/modprobe nvidia
      ${pkgs.kmod}/bin/modprobe nvidia_modeset 2>/dev/null
      ${pkgs.kmod}/bin/modprobe nvidia_drm 2>/dev/null
      systemctl start lactd 2>/dev/null
      exit 0
    '';
  };

  # Two panel readouts for that clamp, since a fix nobody can see is a fix
  # nobody can check. Astra Monitor's GPU menu carries the full picture --
  # Current / Default / Max Power Limit, P-state, memory clock, power draw --
  # and the Executor entry keeps the one number that matters in the top bar.
  # Both extensions come from constellation.desktop.gnome.gpuMonitor above.
  #
  # This is a second dconf database rather than an edit to the desktop module's:
  # databases layer in list order and only keys defined in both would conflict.
  # These keys are defined in neither, so nothing here is at risk of shadowing
  # the shared enabled-extensions list.
  #
  # The instrument is not neutral. Astra polls with `nvidia-smi -q -x -lms`,
  # which is a permanent NVML client this machine did not have before; if the
  # clamp's behaviour changes after this lands, suspect the monitor first.
  programs.dconf.profiles.user.databases = [
    {
      settings = {
        # Executor's commands live in one JSON string per panel position. The
        # left and center defaults are a demo `echo`, so they are turned off.
        "org/gnome/shell/extensions/executor" = {
          left-active = false;
          center-active = false;
          right-active = true;
          right-commands-json = builtins.toJSON {
            commands = [
              {
                isActive = true;
                command = lib.getExe dgpu-power;
                interval = 10;
                uuid = "a1b2c3d4-0d6e-4750-9077-65726361705f";
              }
            ];
          };
        };

        # gpu-data is the list Astra actually polls; gpu-main is the one the
        # panel header shows. Only the dGPU is listed -- adding the Renoir iGPU
        # would start an amdgpu_top poller for a GPU with nothing to watch.
        "org/gnome/shell/extensions/astra-monitor" = {
          gpu-header-show = true;
          gpu-main = builtins.toJSON dgpu;
          gpu-data = builtins.toJSON [(dgpu // {monitor = true;})];
          gpu-update = 5.0; # 2 s by default; this is a laptop and the clamp is not fast
        };
      };
    }
  ];

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
  # instead of overlaying libfprint globally -- the overlay in
  # flake-modules/lib.nix would otherwise put all nine hosts on a libfprint
  # that carries an out-of-tree driver none of them have hardware for.
  #
  # Security note (deliberate, accepted choice, reviewed 2026-09-05): NixOS
  # defaults security.pam.services.<name>.fprintAuth to services.fprintd.enable,
  # so `enable = true` below implicitly inserts `auth sufficient pam_fprintd.so`
  # ahead of pam_unix in every PAM service NixOS generates -- sudo, su,
  # polkit-1, sshd, gdm-fingerprint and others. A fingerprint is therefore
  # sufficient on its own for root escalation via sudo/polkit, not merely a
  # convenience alongside the password. This is intentional: the user has
  # accepted sudo-by-fingerprint knowing the sensor's channel is keyed with a
  # PSK of 32 zero bytes (see the Task 4C/Task 9 fingerprint-sensor spec), so
  # brief physical access to the USB device could capture the image stream.
  #
  # Dual-boot: booting Windows does nothing by itself, but *enrolling in
  # Windows Hello* reverts the sensor to firmware 10034 and provisions a fresh
  # random PSK, after which fprintd fails activation with
  # "Invalid device PSK". Recovery is to reflash from Linux with the zero PSK.
  # The PSK differs on every Windows provisioning, so there is no key to
  # recover and no way to make both OSes work at once -- see Task 9 in the
  # spec, and packages/libfprint-goodix-521d/extract-firmware.py for the
  # 10034 image the reflash needs.
  # sshd picking up pam_fprintd is an inert side effect of the same default --
  # nobody can touch a laptop's internal USB fingerprint sensor over a
  # network session, and `sufficient` just falls through to pam_unix on
  # failure/no-match, so remote password auth is unaffected. Do not set
  # fprintAuth = false anywhere below; that would silently change accepted
  # behaviour. See docs/superpowers/specs/2026-09-05-goodix-521d-fingerprint-design.md
  # for the full writeup.
  services.fprintd = {
    enable = true;
    package = pkgs.fprintd.override {
      libfprint = pkgs.libfprint-goodix-521d;
    };
  };

  # nixpkgs builds the gdm-fingerprint PAM stack from `pkgs.fprintd` rather
  # than `config.services.fprintd.package` (gdm.nix, vs pam.nix which does use
  # the latter), so the override above reaches every PAM service except this
  # one. Login still works -- pam_fprintd links no libfprint, it is a D-Bus
  # client of net.reactivated.Fprint, and the daemon owning that name is ours
  # -- but it is the only thing dragging a second fprintd and a stock
  # libfprint into the system closure. Point it at the same package.
  security.pam.services.gdm-fingerprint.rules.auth.fprintd.modulePath =
    lib.mkForce "${config.services.fprintd.package}/lib/security/pam_fprintd.so";

  # Disable firewall for development
  networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  system.stateVersion = "23.11";
}
