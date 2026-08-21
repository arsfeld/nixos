# Gaming configuration module inspired by Bazzite
# Provides comprehensive gaming setup with performance optimizations
{
  config,
  options,
  pkgs,
  lib,
  ...
}: let
  cfg = config.constellation.gaming;

  # Toggles gaming-boost.service. gamemoded runs as a *user* service, so its
  # custom start/end hooks cannot set properties on a system unit themselves;
  # this plus the polkit rule below is the privilege bridge.
  gamingBoost = pkgs.writeShellApplication {
    name = "gaming-boost";
    runtimeInputs = [config.systemd.package];
    text = ''
      case "''${1:-}" in
        on) exec systemctl start --no-block gaming-boost.service ;;
        off) exec systemctl stop --no-block gaming-boost.service ;;
        *)
          echo "usage: gaming-boost on|off" >&2
          exit 2
          ;;
      esac
    '';
  };
in {
  options.constellation.gaming = {
    enable = lib.mkEnableOption "gaming configuration with Bazzite-style optimizations";

    kernelOptimizations = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable gaming kernel optimizations";
    };

    gamingMode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Hook gamemode's start/end events so background build capacity yields to
        the running game (see backgroundCpus). Replaces the old gaming-mode
        unit, which pkill'd dev processes and dropped the page cache the game
        was about to need.
      '';
    };

    backgroundCpus = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "8-15";
      description = ''
        CPU set that background build work (nix-daemon) is confined to while a
        game runs, as a systemd AllowedCPUs= value. Null leaves the CPU set
        alone and applies only the CPUWeight/IOWeight de-prioritisation.

        This is the knob that actually makes builds yield. nix-daemon.service
        lives in system.slice and a game lives in user.slice, and CPUWeight only
        arbitrates between siblings sharing a parent cgroup — so weight alone
        reorders nix-daemon against other system.slice units and never against
        the game. AllowedCPUs is absolute and works across the tree.

        Set it to the efficiency cores on a hybrid CPU. On raider's i5-12500H,
        "8-15" is the eight E-cores; 0-7 are the four SMT P-cores.
      '';
    };

    cpuVendor = lib.mkOption {
      type = lib.types.enum ["amd" "intel" "none"];
      default = "amd";
      description = "CPU vendor for frequency driver selection (amd_pstate or intel_pstate)";
    };

    performanceOsd = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable MangoHud performance overlay with Steam Deck-style preset cycling";
    };

    scheduler = lib.mkOption {
      type = lib.types.enum ["none" "lavd" "bpfland" "rusty"];
      default = "lavd";
      description = ''
        sched_ext BPF scheduler to run via services.scx-loader.
        - lavd: Latency-Aware Virtual Deadline (recommended, mixed desktop + dev + gaming)
        - bpfland: Simpler priority model, pure gaming boxes
        - rusty: Multi-domain round-robin, heavy compile workloads (hurts game latency)
        - none: Stock CFS (no scx daemon)
        The scx daemon auto-unloads the BPF program on failure, falling back to CFS.
      '';
    };

    wineTuning = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Wine/Proton performance tuning: ntsync kernel module (+ uaccess udev
          rule), UMU launcher, moonlight-qt client, and relocation of DXVK/
          VKD3D/Mesa shader caches to /var/cache with higher size limits.
        '';
      };
    };

    gamescope = {
      width = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = ''
          Forced gamescope output width (-W). Null leaves it unset so gamescope
          uses the native display resolution — correct default for laptops and
          anything that isn't a fixed known panel. Set per-host (e.g. an
          ultrawide desktop) when you want to pin the output mode.
        '';
      };
      height = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Forced gamescope output height (-H). Null = native resolution.";
      };
      refreshRate = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Forced gamescope refresh rate (-r). Null = native refresh rate.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf config.constellation.gaming.enable {
      # Gaming kernel optimizations
      boot = lib.mkIf config.constellation.gaming.kernelOptimizations {
        kernelPackages = lib.mkOverride 990 pkgs.linuxPackages_xanmod_latest;

        kernelParams =
          [
            # Performance optimizations
            "mitigations=off"
            "nowatchdog"
            "nmi_watchdog=0"

            # Memory and I/O optimizations
            "transparent_hugepage=always"
            "vm.max_map_count=2147483642"

            # Gaming-specific tweaks from SteamOS
            "split_lock_detect=off"
            "pci=noaer"
            "preempt=full"

            # Disable debug features
            "loglevel=3"
            "rd.udev.log_level=3"
            "systemd.show_status=false"

            # Disable zswap - conflicts with zram (double compression wastes RAM)
            "zswap.enabled=0"

            # Enable Pressure Stall Information (PSI metrics for monitoring)
            "psi=1"
          ]
          ++ lib.optional (config.constellation.gaming.cpuVendor == "amd") "amd_pstate=active"
          ++ lib.optional (config.constellation.gaming.cpuVendor == "intel") "intel_pstate=active";

        kernel.sysctl = {
          # Network optimizations (BBR congestion control)
          "net.core.default_qdisc" = "cake";
          "net.ipv4.tcp_congestion_control" = "bbr";

          # Memory management (zram is RAM-backed, not disk; a moderately high
          # swappiness encourages compressing cold pages to free RAM for active
          # use). 100 was too aggressive — it evicted warm file-cache pages of
          # interactive apps under build load, causing major-fault storms and
          # desktop stalls. 80 still favours zram compression without thrashing.
          "vm.swappiness" = lib.mkDefault 80;
          "vm.vfs_cache_pressure" = 50;
          "vm.dirty_background_ratio" = 5;
          "vm.dirty_ratio" = 10;
          "vm.dirty_writeback_centisecs" = 1500; # 15s periodic writeback (reduces I/O stutter)
          "vm.compaction_proactiveness" = 0; # Disable proactive THP compaction (reduces latency spikes)

          # Gaming performance.
          # NOTE: the old kernel.sched_child_runs_first / sched_latency_ns /
          # sched_min_granularity_ns / sched_wakeup_granularity_ns knobs were
          # removed — they don't exist on EEVDF kernels (xanmod 6.6+) and are
          # doubly moot here since scx_lavd (services.scx-loader) replaces CFS entirely.
          "kernel.sched_autogroup_enabled" = 1;
          "kernel.split_lock_mitigate" = 0;

          # File system
          "fs.file-max" = 2097152;
          "fs.aio-max-nr" = 1048576;

          # Socket buffer sizing, backlog, keepalive and MTU probing are left to
          # bpftune (services.bpftune below), which resizes them from observed
          # load. Static values here would be boot-time hints that bpftune
          # immediately overrides, leaving the declared config no longer
          # describing the running system. The two below aren't things bpftune
          # sizes, so they stay declarative — as do cake/bbr further up.
          "net.ipv4.tcp_fastopen" = 3;
          "net.ipv4.tcp_syncookies" = 1;

          # SHM (shared memory) for games
          "kernel.shmmax" = 68719476736;
          "kernel.shmall" = 4294967296;
        };

        extraModulePackages = with config.boot.kernelPackages; [
          v4l2loopback # Virtual camera support for streaming
        ];

        # ntsync: Wine/Proton synchronization primitive, in-tree since 6.14.
        # Loading the module eagerly exposes /dev/ntsync to the udev rule below.
        kernelModules =
          lib.optionals config.constellation.gaming.wineTuning.enable ["ntsync"]
          # bfq must be loaded for the SATA-SSD/HDD scheduler rules below to apply.
          ++ lib.optionals config.constellation.gaming.kernelOptimizations ["bfq"];

        blacklistedKernelModules = [
          "iTCO_wdt" # Disable watchdog
          "sp5100_tco" # AMD watchdog
        ];
      };

      # I/O scheduler tuning per device type + ntsync access for the active session
      services.udev.extraRules =
        lib.optionalString config.constellation.gaming.kernelOptimizations ''
          # NVMe: bypass scheduler (hardware handles queuing)
          ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
          # SATA SSD: bfq. This module also runs ananicy-cpp, which tags build
          # tools (rustc, cc1, cargo, ld, …) with the idle IO class so heavy
          # background builds yield the disk to interactive apps. mq-deadline
          # ignores IO priorities, so that tag did nothing on a SATA SSD (e.g.
          # /home) and a build there would freeze the desktop. bfq honours the
          # priorities and is built for interactivity under load.
          ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="bfq"
          # HDD: bfq (fair queuing, good for rotational)
          ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
        ''
        + lib.optionalString config.constellation.gaming.wineTuning.enable ''
          # ntsync: world-accessible Wine sync device. uaccess doesn't work
          # here because ntsync is a virtual misc device, not seat-bound, so
          # logind won't grant per-session ACLs. 0666 is what Arch/Bazzite ship.
          KERNEL=="ntsync", MODE="0666"
        '';

      # Wine/Proton tuning: relocate DXVK/VKD3D/Mesa shader caches to /var/cache
      # (on the fast NVMe), raise size limits so AAA titles don't thrash, and
      # tell Proton to use ntsync. 1777 sticky mode matches /tmp's trust model
      # so multiple users can populate caches without cross-user delete.
      environment.sessionVariables = lib.mkIf config.constellation.gaming.wineTuning.enable {
        DXVK_STATE_CACHE_PATH = "/var/cache/dxvk";
        DXVK_STATE_CACHE_MAX_ENTRIES = "2000000";
        __GL_SHADER_DISK_CACHE_PATH = "/var/cache/gl-shaders";
        MESA_SHADER_CACHE_DIR = "/var/cache/mesa-shaders";
        MESA_SHADER_CACHE_MAX_SIZE = "2G";
        PROTON_USE_NTSYNC = "1";
      };

      systemd.tmpfiles.rules = lib.mkIf config.constellation.gaming.wineTuning.enable [
        "d /var/cache/dxvk 1777 root root - -"
        "d /var/cache/gl-shaders 1777 root root - -"
        "d /var/cache/mesa-shaders 1777 root root - -"
      ];

      # Enable ZRAM for better memory management
      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 25;
      };

      # OOM protection - prevent system freeze under memory pressure
      services.earlyoom = {
        enable = true;
        freeMemThreshold = 5;
        freeMemKillThreshold = 2;
        freeSwapThreshold = 10;
        enableNotifications = true;
        extraArgs = [
          "--prefer"
          "(^|/)(nix-daemon|cc1plus|cc1|c\\+\\+|ld|lld)$"
          "--avoid"
          "(^|/)(Xwayland|gnome-shell|gamescope|steam)$"
        ];
      };

      # earlyoom (above) is our single userspace OOM killer: it acts on real
      # free-memory + free-swap thresholds with the prefer/avoid lists tuned for
      # build-vs-game contention. NixOS enables systemd-oomd by default, which
      # would be a second killer racing on PSI pressure with different policy —
      # disable it so kill decisions come from one place.
      systemd.oomd.enable = lib.mkForce false;

      # Core Gaming Software
      programs = {
        # Steam with all features
        steam = {
          enable = true;
          remotePlay.openFirewall = true;
          dedicatedServer.openFirewall = true;
          gamescopeSession.enable = true;

          extraCompatPackages = with pkgs; [
            proton-ge-bin
          ];

          # Native GTK theme for Steam
          package = pkgs.steam.override {
            extraEnv = lib.optionalAttrs config.constellation.gaming.performanceOsd {
              MANGOHUD = "1";
            };
            extraPkgs = pkgs:
              with pkgs; [
                adwsteamgtk # Adwaita theme manager for Steam
              ];
            extraLibraries = pkgs: [];
          };
        };

        # GameMode for automatic optimizations
        gamemode = {
          enable = true;
          settings =
            {
              general = {
                renice = 10;
                inhibit_screensaver = 1;
              };

              gpu = {
                apply_gpu_optimisations = "accept-responsibility";
                gpu_device = 0;
                amd_performance_level = "high";
                nv_powermizer_mode = 1;
              };

              cpu = {
                park_cores = "no";
                pin_cores = "yes";
              };
            }
            // lib.optionalAttrs cfg.gamingMode {
              # Ride gamemode's own lifecycle rather than a manual toggle. These
              # fire for anything launched via gamemoderun — Lutris/Heroic/Bottles
              # do that by default, bare Steam needs `gamemoderun %command%` in
              # the launch options. That is the same gate which already governs
              # gpu.amd_performance_level above, so it is not a new limitation.
              custom = {
                start = "${gamingBoost}/bin/gaming-boost on";
                end = "${gamingBoost}/bin/gaming-boost off";
              };
            };
        };

        # Gamescope compositor
        gamescope = let
          gs = config.constellation.gaming.gamescope;
        in {
          enable = true;
          capSysNice = false;
          # Output mode (-W/-H/-r) is host-configurable via
          # constellation.gaming.gamescope.*. When unset, gamescope picks the
          # native display mode — the right default for laptops. Pin it per-host
          # for fixed panels (e.g. raider's 3440x1440@144 ultrawide).
          args =
            [
              "--adaptive-sync"
              "--immediate-flips"
              "--force-grab-cursor"
              # FSR upscaling — sharp Lanczos+RCAS instead of blurry bilinear
              # when a game's render resolution doesn't match the output.
              "-F fsr"
            ]
            ++ lib.optional (gs.width != null) "-W ${toString gs.width}"
            ++ lib.optional (gs.height != null) "-H ${toString gs.height}"
            ++ lib.optional (gs.refreshRate != null) "-r ${toString gs.refreshRate}"
            ++ ["-f"];
        };
      };

      # Gaming packages
      environment.systemPackages = with pkgs;
        [
          # Gaming platforms
          lutris
          bottles
          heroic
          itch

          # Wine and compatibility
          wineWow64Packages.stagingFull
          winetricks
          protontricks
          protonplus # GUI Proton-GE / compat-tool manager (updater for the baked proton-ge-bin)

          # Performance monitoring
          goverlay
          vkbasalt

          # Frame generation: Lossless Scaling as a Vulkan implicit layer + its
          # config GUI. GPU-vendor-agnostic (NVIDIA + AMD). The layer is inert
          # until configured and requires owning the paid "Lossless Scaling"
          # Steam app (Lossless.dll) to actually generate frames.
          lsfg-vk
          lsfg-vk-ui

          # System monitoring
          mission-center
          resources
          nvtopPackages.full

          # Input management
          antimicrox
          sc-controller
          jstest-gtk
          game-devices-udev-rules

          # Streaming and recording
          obs-studio
          obs-studio-plugins.obs-vkcapture
          obs-studio-plugins.obs-vaapi
          obs-studio-plugins.obs-pipewire-audio-capture
          gpu-screen-recorder
          gpu-screen-recorder-gtk

          # Discord
          (discord.override {
            withOpenASAR = true;
            withVencord = true;
          })

          # Vulkan tools
          vulkan-tools
          vulkan-loader
          vulkan-validation-layers
          vulkan-extension-layer

          # Additional gaming tools
          r2modman
          steamtinkerlaunch
          legendary-gl
          rare

          # Steam theming
          adwsteamgtk # GUI tool to install and manage Adwaita theme for Steam

          # Emulation
          retroarch
          retroarch-assets
          retroarch-joypad-autoconfig

          # RGB and hardware control
          openrgb-with-all-plugins
          piper
          solaar
          liquidctl
        ]
        ++ lib.optionals config.constellation.gaming.wineTuning.enable [
          # Unified launcher for non-Steam Proton games (upstream for Lutris/Heroic/Bottles).
          pkgs.umu-launcher
          # Moonlight client so raider can also receive streams from other Sunshine hosts.
          pkgs.moonlight-qt
        ]
        # AMD mobile TDP tuning. Gated on cpuVendor so it lands on Ryzen laptops
        # (blackbird) and skips Intel hosts (raider) automatically.
        ++ lib.optional (config.constellation.gaming.cpuVendor == "amd") pkgs.ryzenadj;

      # Hardware support
      hardware = {
        # Controller support
        xone.enable = true;
        xpadneo.enable = true;
        steam-hardware.enable = true;

        # Logitech support
        logitech.wireless = {
          enable = true;
          enableGraphical = true;
        };
      };

      # Audio optimizations for gaming
      services.pipewire.wireplumber.configPackages = lib.mkIf config.services.pipewire.enable [
        (pkgs.writeTextDir "share/wireplumber/wireplumber.conf.d/51-alsa-gaming.conf" ''
          monitor.alsa.rules = [
            {
              matches = [
                {
                  node.name = "~alsa_output.*"
                }
              ]
              actions = {
                update-props = {
                  api.alsa.period-size = 256
                  api.alsa.period-num = 3
                  api.alsa.headroom = 1024
                  session.suspend-timeout-seconds = 0
                  resample.quality = 10
                  resample.disable = false
                  channelmix.normalize = false
                  channelmix.mix-lfe = false
                  audio.channels = 2
                  audio.format = "S24_LE"
                  audio.rate = 48000
                  audio.position = "FL,FR"
                }
              }
            }
          ]
        '')
      ];

      # Service configuration
      services = {
        # Input management
        ratbagd.enable = true;
        joycond.enable = true;

        # LACT replaces corectrl. lactd applies saved fan/power/clock profiles at
        # boot, headless; corectrl only applied its settings while its tray app
        # was running in the session. Not gated on cpuVendor — LACT drives NVIDIA
        # too. hardware.amdgpu.overdrive.enable (required for custom fan curves
        # and undervolting) is deliberately left off: it adds
        # amdgpu.ppfeaturemask=0xffffffff at boot and is a separate decision.
        lact.enable = true;

        # BPF-driven network autotuning, replacing the static net.core.*/
        # net.ipv4.tcp_* buffer sizing that used to sit in boot.kernel.sysctl.
        # Note upstream bpftune has none of Bazzite's game-detection patches —
        # this is generic TCP/neigh autotuning.
        bpftune.enable = true;

        # Power management for gaming
        tlp = {
          enable = lib.mkDefault false; # Usually conflicts with gaming
        };
      };

      # Yield background build capacity to a running game.
      #
      # This replaces the old gaming-mode unit, which pkill'd anything matching
      # "python|pip"/"cargo|rustc"/"node|npm", stopped postgres/libvirt/containers
      # and ran `echo 3 > /proc/sys/vm/drop_caches` — throwing away the page cache
      # the game was about to need, and duplicating (badly) what ananicy-cpp below
      # already does correctly. Bazzite made the same move away from killing
      # background work and toward boosting the foreground app (dmemcg-booster,
      # uresourced-dmemcg).
      #
      # Properties are set --runtime so nothing survives a reboot, and assigning a
      # property an empty value resets it to the unit's default.
      systemd.services.gaming-boost = lib.mkIf cfg.gamingMode {
        description = "Yield background build capacity to a running game";
        serviceConfig = let
          setProperty = args: "${config.systemd.package}/bin/systemctl set-property --runtime nix-daemon.service ${lib.escapeShellArgs args}";
          applied =
            ["CPUWeight=20" "IOWeight=20"]
            ++ lib.optional (cfg.backgroundCpus != null) "AllowedCPUs=${cfg.backgroundCpus}";
          cleared =
            ["CPUWeight=" "IOWeight="]
            ++ lib.optional (cfg.backgroundCpus != null) "AllowedCPUs=";
        in {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = setProperty applied;
          ExecStop = setProperty cleared;
        };
      };

      # gamemoded runs as a user service and so cannot manage a system unit on its
      # own. Scope the grant to this one unit; wheel rather than the gamemode group
      # because processes under user@.service are not attached to a logind session,
      # which makes subject.active/subject.local unreliable here, and wheel already
      # holds full sudo — this adds no privilege.
      security.polkit.extraConfig = lib.mkIf cfg.gamingMode ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "gaming-boost.service" &&
              subject.isInGroup("wheel")) {
            return polkit.Result.YES;
          }
        });
      '';

      # Process priority daemon — lowers Steam client/download CPU priority
      # while leaving games at normal priority. CachyOS rules cover game
      # processes (wine_proton/linux-native) with "Game" type (nice -5), so
      # games launched by Steam get boosted back up even if they inherit
      # Steam's nice value at fork time.
      services.ananicy = {
        enable = true;
        package = pkgs.ananicy-cpp;
        rulesProvider = pkgs.ananicy-rules-cachyos;
        # Native Linux Steam client rules — CachyOS rules only cover Windows
        # Steam.exe under Wine. We use nice+ionice (not SCHED_IDLE) so that
        # games inheriting policy aren't stuck at idle priority.
        extraRules = [
          {
            name = "steam";
            nice = 15;
            ioclass = "best-effort";
            ionice = 7;
          }
          {
            name = "steamwebhelper";
            nice = 15;
            ioclass = "best-effort";
            ionice = 7;
          }
          {
            name = "steam-runtime-l";
            nice = 15;
            ioclass = "best-effort";
            ionice = 7;
          }
          {
            name = "srt-bwrap";
            nice = 15;
            ioclass = "best-effort";
            ionice = 7;
          }
        ];
      };

      # Security settings that don't impact gaming
      security = {
        pam.loginLimits = [
          {
            domain = "@gamemode";
            item = "nice";
            type = "-";
            value = "-20";
          }
        ];

        allowSimultaneousMultithreading = true;
        forcePageTableIsolation = false;
        virtualisation.flushL1DataCache = "never";
      };

      # User groups for gaming
      users.groups.gamemode = {};

      # Firewall rules for gaming
      networking.firewall = {
        allowedTCPPorts = [27036 27037]; # Steam
        allowedUDPPorts = [27031 27036]; # Steam
      };

      # Sunshine: install the LizardByte prerelease Flatpak bundle that ships
      # XDG portal + PipeWire capture (upstream PR #4417). The Flathub stable
      # branch is still on v2025.924.154138 which only supports KMS/wlr
      # capture — neither works on GNOME Wayland with Mutter. The master
      # bundle uses portal capture, which Mutter implements, so streaming
      # works without leaving Wayland or touching KMS capabilities.
      services.flatpak.packages = [
        {
          appId = "dev.lizardbyte.app.Sunshine";
          bundle = "${pkgs.fetchurl {
            url = "https://github.com/LizardByte/Sunshine/releases/download/v2026.412.25828/sunshine_x86_64.flatpak";
            hash = "sha256-9QFEK46jWKikHwPrqbhe6esniAQi6KlV8n9szEtzdQo=";
          }}";
          # nix-flatpak uses the sha256 field to detect bundle changes and
          # trigger uninstall+reinstall. Without this it skips bundles entirely.
          sha256 = "f501442b8ea358a8a41f03eba9b85ee9eb27880422e8a955f27f6ccc4b73750a";
        }
      ];

      # Autostart the Sunshine Flatpak in the user's graphical session.
      # First-run still requires manual portal consent via the monitor-
      # selection dialog from xdg-desktop-portal-gnome; the token persists
      # under ~/.var/app/dev.lizardbyte.app.Sunshine after that.
      systemd.user.services.sunshine = {
        description = "Sunshine self-hosted game stream host for Moonlight";
        wantedBy = ["graphical-session.target"];
        partOf = ["graphical-session.target"];
        after = ["graphical-session.target"];
        serviceConfig = {
          ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
          ExecStart = "${pkgs.flatpak}/bin/flatpak run --branch=master --command=sunshine dev.lizardbyte.app.Sunshine";
          ExecStop = "${pkgs.flatpak}/bin/flatpak kill dev.lizardbyte.app.Sunshine";
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };

      # Fonts for game compatibility
      fonts = {
        packages = with pkgs; [
          corefonts
          vista-fonts
        ];

        fontconfig = {
          cache32Bit = true;
          allowBitmaps = true;
        };
      };
    })
    # sched_ext BPF scheduler (replaces the old system76-scheduler, which
    # caused high context switches and freezing). scx_lavd is CachyOS/Bazzite's
    # default for mixed desktop + dev + gaming workloads. Auto-falls back to
    # CFS if the BPF program errors. Requires kernel >= 6.12 (xanmod_latest).
    #
    # scx-loader rather than the static services.scx: same daemon, same default
    # scheduler, but it also owns org.scx.Loader on the system bus so the
    # scheduler can be switched at runtime. We deliberately do NOT switch to its
    # Gaming mode from the gamemode hook — scx_lavd's default is already
    # --autopilot (it picks performance/powersave/balanced from load, and is
    # mutually exclusive with the --performance that Gaming mode would pass), so
    # switching would mostly duplicate autopilot while costing a BPF
    # unload/reload stall at both game start and exit.
    #
    # scx-loader landed in nixpkgs after 26.05, so it exists only for hosts in
    # `unstableHosts`. Hosts on stable fall back to services.scx: same daemon,
    # same scheduler, minus the org.scx.Loader D-Bus interface. This lives as
    # its own lib.mkMerge branch (rather than merged into `services` above via
    # `// lib.optionalAttrs`) because gaming.nix's `services` value has several
    # sibling dotted bindings (services.udev.extraRules, services.earlyoom,
    # etc.) elsewhere in this file — making the `services = { ... };` binding's
    # RHS a non-literal expression breaks Nix's own attrpath-merge sugar for
    # those, raising "attribute 'services' already defined". mkIf/mkMerge at
    # the config level sidesteps that: the module system merges `services.scx`
    # or `services.scx-loader` in below with the plain `services = { ... };`
    # literal above without touching its syntax.
    (lib.mkIf (config.constellation.gaming.enable && cfg.scheduler != "none") (
      if options.services ? scx-loader
      then {
        services.scx-loader = {
          enable = true;
          config.default_sched = "scx_${cfg.scheduler}";
        };
      }
      else {
        services.scx = {
          enable = true;
          scheduler = "scx_${cfg.scheduler}";
        };
      }
    ))
  ];
}
