# Gaming configuration module inspired by Bazzite
# Provides comprehensive gaming setup with performance optimizations
{
  config,
  pkgs,
  lib,
  ...
}: {
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
      description = "Enable gaming mode toggle for stopping development services";
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
  };

  config = lib.mkIf config.constellation.gaming.enable {
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

          # Enable Pressure Stall Information for systemd-oomd
          "psi=1"
        ]
        ++ lib.optional (config.constellation.gaming.cpuVendor == "amd") "amd_pstate=active"
        ++ lib.optional (config.constellation.gaming.cpuVendor == "intel") "intel_pstate=active";

      kernel.sysctl = {
        # Network optimizations (BBR congestion control)
        "net.core.default_qdisc" = "cake";
        "net.ipv4.tcp_congestion" = "bbr";

        # Memory management (zram is RAM-backed, not disk; higher swappiness
        # encourages compressing cold pages to free RAM for active use)
        "vm.swappiness" = lib.mkDefault 100;
        "vm.vfs_cache_pressure" = 50;
        "vm.dirty_background_ratio" = 5;
        "vm.dirty_ratio" = 10;
        "vm.dirty_writeback_centisecs" = 1500; # 15s periodic writeback (reduces I/O stutter)
        "vm.compaction_proactiveness" = 0; # Disable proactive THP compaction (reduces latency spikes)

        # Gaming performance
        "kernel.sched_child_runs_first" = 0;
        "kernel.sched_autogroup_enabled" = 1;
        "kernel.split_lock_mitigate" = 0;

        # BORE scheduler tuning for desktop interactivity
        "kernel.sched_latency_ns" = lib.mkDefault 1000000; # 1ms
        "kernel.sched_min_granularity_ns" = lib.mkDefault 100000; # 0.1ms
        "kernel.sched_wakeup_granularity_ns" = lib.mkDefault 500000; # 0.5ms

        # File system
        "fs.file-max" = 2097152;
        "fs.aio-max-nr" = 1048576;

        # Network buffers for online gaming
        "net.core.rmem_default" = 131072;
        "net.core.rmem_max" = 134217728;
        "net.core.wmem_default" = 131072;
        "net.core.wmem_max" = 134217728;
        "net.core.netdev_max_backlog" = 65536;
        "net.core.optmem_max" = 65536;
        "net.ipv4.tcp_rmem" = "8192 262144 134217728";
        "net.ipv4.tcp_wmem" = "8192 65536 134217728";
        "net.ipv4.tcp_fastopen" = 3;
        "net.ipv4.tcp_keepalive_time" = 60;
        "net.ipv4.tcp_keepalive_intvl" = 10;
        "net.ipv4.tcp_keepalive_probes" = 6;
        "net.ipv4.tcp_mtu_probing" = 1;
        "net.ipv4.tcp_syncookies" = 1;

        # SHM (shared memory) for games
        "kernel.shmmax" = 68719476736;
        "kernel.shmall" = 4294967296;
      };

      extraModulePackages = with config.boot.kernelPackages; [
        v4l2loopback # Virtual camera support for streaming
      ];

      blacklistedKernelModules = [
        "iTCO_wdt" # Disable watchdog
        "sp5100_tco" # AMD watchdog
      ];
    };

    # I/O scheduler tuning per device type
    services.udev.extraRules = lib.mkIf config.constellation.gaming.kernelOptimizations ''
      # NVMe: bypass scheduler (hardware handles queuing)
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
      # SATA SSD: mq-deadline (low overhead, good for random I/O)
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
      # HDD: bfq (fair queuing, good for rotational)
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
    '';

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

    # Per-slice memory pressure monitoring
    systemd.oomd = {
      enableRootSlice = true;
      enableUserSlices = true;
    };

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
        settings = {
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
        };
      };

      # Gamescope compositor
      gamescope = {
        enable = true;
        capSysNice = true;
        args = [
          "--adaptive-sync"
          "--immediate-flips"
          "--force-grab-cursor"
        ];
      };

      # CoreCtrl for GPU management
      corectrl.enable = true;
    };

    # Gaming packages
    environment.systemPackages = with pkgs; [
      # Gaming platforms
      lutris
      bottles
      heroic
      itch

      # Wine and compatibility
      wineWowPackages.stagingFull
      winetricks
      protontricks

      # Performance monitoring
      goverlay
      vkbasalt

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
    ];

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

      # System optimization
      system76-scheduler.enable = false; # Disabled - causes high context switches and freezing

      # Power management for gaming
      tlp = {
        enable = lib.mkDefault false; # Usually conflicts with gaming
      };
    };

    # Gaming mode service (stops development services)
    systemd.services.gaming-mode = lib.mkIf config.constellation.gaming.gamingMode {
      description = "Gaming Mode - Stop development services for maximum performance";
      after = ["multi-user.target"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart = ''
          ${pkgs.bash}/bin/bash -c '
            echo "Activating gaming mode..."

            # Stop Docker if it exists
            if systemctl list-units --all | grep -q docker.service; then
              ${pkgs.docker}/bin/docker stop $(${pkgs.docker}/bin/docker ps -q) 2>/dev/null || true
              systemctl stop docker.service docker.socket 2>/dev/null || true
            fi

            # Stop Podman if it exists
            if systemctl list-units --all | grep -q podman.service; then
              ${pkgs.podman}/bin/podman stop --all 2>/dev/null || true
              systemctl stop podman.service podman.socket 2>/dev/null || true
            fi

            # Stop development services
            for service in postgresql mysql mongodb redis elasticsearch kibana rabbitmq; do
              systemctl stop "$service" 2>/dev/null || true
            done

            # Stop virtualization
            systemctl stop libvirtd 2>/dev/null || true

            # Kill development processes
            pkill -f "node|npm|yarn|pnpm" || true
            pkill -f "cargo|rustc" || true
            pkill -f "go build|go run" || true
            pkill -f "python|pip" || true

            # Clear caches
            sync
            echo 3 > /proc/sys/vm/drop_caches

            echo "Gaming mode activated!"
          '
        '';

        ExecStop = ''
          ${pkgs.bash}/bin/bash -c '
            echo "Deactivating gaming mode..."

            # Restart Docker if it was installed
            if systemctl list-units --all | grep -q docker.service; then
              systemctl start docker.socket docker.service 2>/dev/null || true
            fi

            # Restart Podman if it was installed
            if systemctl list-units --all | grep -q podman.service; then
              systemctl start podman.socket podman.service 2>/dev/null || true
            fi

            echo "Gaming mode deactivated!"
          '
        '';
      };
    };

    # Gaming-related aliases
    programs.bash.shellAliases = lib.mkIf config.constellation.gaming.gamingMode {
      gaming-on = "sudo systemctl start gaming-mode";
      gaming-off = "sudo systemctl stop gaming-mode";
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
    users.groups = {
      gamemode = {};
      corectrl = {};
    };

    # Firewall rules for gaming
    networking.firewall = {
      allowedTCPPorts = [27036 27037]; # Steam
      allowedUDPPorts = [27031 27036]; # Steam
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
  };
}
