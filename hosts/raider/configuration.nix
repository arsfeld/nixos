{
  self,
  inputs,
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./disko-config.nix
    ./fan-control.nix
    ./fontconfig.nix
    ./harmonia.nix
    ./samba.nix
    inputs.niks3.nixosModules.niks3-auto-upload
  ];

  # Enable sops-nix for secrets management
  constellation.sops.enable = true;

  # Stash secrets
  sops.secrets."stash-jwt-secret" = {
    owner = "media";
    group = "media";
  };
  sops.secrets."stash-session-secret" = {
    owner = "media";
    group = "media";
  };

  # Publisher credential for claude-notify (authenticated ntfy.arsfeld.one
  # publishes). owner + mode let the user-mode script read it directly.
  sops.secrets."ntfy-publisher-env" = {
    sopsFile = ../../secrets/sops/ntfy-client.yaml;
    owner = "arosenfeld";
    mode = "0400";
  };

  # Full-write cache credential on a workstation, which is worth naming
  # explicitly. niks3 supports exactly one API token alongside OIDC, so there
  # is no lower-privilege token to hand raider short of mTLS. It is not a
  # regression: raider already held an attic write token in
  # ~/.config/attic/config.toml.
  #
  # owner + mode let the interactive user read it, not just root. The
  # auto-upload daemon runs as root and could read it either way; the reason
  # for the user-readable mode is `nix-fast-build --niks3-server`, whose
  # upload worker shells out to `niks3 push` as the invoking user and resolves
  # its token from $NIKS3_AUTH_TOKEN_FILE. That avoids a second copy of the
  # token in ~/.config/niks3/auth-token.
  sops.secrets."niks3-api-token" = {
    owner = "arosenfeld";
    mode = "0400";
  };

  # Every derivation raider builds is uploaded as it finishes — not just what
  # CI builds or what `just deploy` pushes.
  #
  # The post-build hook itself does almost nothing: it writes the store path
  # to a unix socket and exits. That matters, because a post-build hook runs
  # inside every build, and one that uploaded synchronously would serialise
  # every build behind network I/O. The socket-activated daemon on the other
  # end batches 50 paths, uploads with 30-way concurrency, and exits after 60s
  # idle; behind it is a WAL-mode SQLite queue, so paths survive a crash or a
  # reboot mid-upload instead of being silently lost.
  #
  # raider only. blackbird is a laptop that is frequently tethered or offline,
  # and pushing every local build over a metered link is the wrong default;
  # galactica and basestar are deploy targets that rarely build anything not
  # already coming from CI.
  #
  # Note that post-build-hook is a global nix setting, not a list. Nothing
  # else in this repo sets one today, but a future module that wants one will
  # collide with this rather than compose with it.
  services.niks3-auto-upload = {
    enable = true;
    serverUrl = "https://niks3.arsfeld.dev";
    authTokenFile = config.sops.secrets."niks3-api-token".path;
  };

  # Allow insecure packages
  nixpkgs.config.permittedInsecurePackages = [
    "mbedtls-2.28.10"
  ];

  # Enable constellation modules
  constellation = {
    desktop = {
      enable = true;
      variant = "gnome";
      gnome.theme = {
        gtk = "WhiteSur-Dark";
        icon = "WhiteSur-dark";
      };
    };
    gaming = {
      enable = true;
      cpuVendor = "intel";
      # i5-12500H: CPUs 0-7 are the four SMT P-cores (4500 MHz), 8-15 the eight
      # E-cores (3300 MHz). Confine nix-daemon to the E-cores while a game runs
      # so builds never contend for a P-core with the game.
      backgroundCpus = "8-15";
      # 3440x1440@144 ultrawide — pin gamescope's output mode to the panel.
      gamescope = {
        width = 3440;
        height = 1440;
        refreshRate = 144;
      };
    };
    development.enable = true;
    docker.enable = true; # Enable Docker runtime
    backrest = {
      # Interval-based scheduler matches laptop usage: runs ~24h after the
      # last successful run, catches up once after long suspensions
      # instead of stacking skipped cron entries.
      enable = true;
      repos.storage = {
        uri = "rest:http://galactica.bat-boa.ts.net:8000/";
        passwordFile = config.sops.secrets."restic-password".path;
        # galactica owns prune and check for this repo (it hosts the disk).
        # Three instances pruning one repository would contend for one lock.
        prune = null;
        check = null;
      };
      plans.system = {
        repo = "storage";
        paths = ["/var/lib" "/home" "/root"];
        excludes = [
          "/var/lib/docker"
          "/var/lib/containers"
          "/var/lib/systemd"
          "/var/lib/libvirt"
          "/var/lib/lxcfs"
          "/var/cache"
          "/nix"
          "/mnt"
          "**/.cache"
          "**/.nix-profile"
          # Rootless podman image storage. On galactica this was 1.56M files for
          # almost no bytes — two thirds of that repo's file count. Every layer is
          # re-pullable from a registry. Excluded fleet-wide so the same doesn't
          # accumulate here unnoticed.
          "**/.local/share/containers"
        ];
        excludeIfPresent = [".nobackup" "CACHEDIR.TAG"];
        schedule = {
          maxFrequencyHours = 24;
          clock = "last-run";
        };
        # Was keep-all, which combined with the absent prune policy meant nothing
        # was ever removed from this repo. Matches the d7/w4/m6 that galactica
        # already uses for its hetzner and pegasus plans.
        retention = {
          daily = 7;
          weekly = 4;
          monthly = 6;
        };
      };
    };
  };

  # Project Isolation VMs (Tailscale disabled for now — uses libvirt network SSH)
  constellation.projectVms = {
    enable = true;
    sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDeQP9ZHuDegrcgBEAuLpCWEK0v8eIBAgaLMSquCP0w arsfeld@gmail.com";
  };

  # Mark raider as a development machine for netdata alert filtering
  services.netdata.config."host labels".environment = "development";

  # Enable media config for domain settings (required by constellation.services)
  media.config.enable = true;

  # Create stashapp-tools Python package (needed by AI Tagger plugin)
  nixpkgs.overlays = [
    (final: prev: {
      stashapp-tools = prev.python3Packages.buildPythonPackage rec {
        pname = "stashapp-tools";
        version = "0.2.59";
        format = "setuptools";

        src = prev.fetchPypi {
          inherit pname version;
          hash = "sha256-Y52YueWHp8C2FsnJ01YMBkz4O2z4d7RBeCswWGr8SjY=";
        };

        propagatedBuildInputs = with prev.python3Packages; [
          requests
        ];

        pythonImportsCheck = ["stashapi"];
      };

      # Python environment with required packages for Stash plugins
      stashPython = prev.python3.withPackages (ps:
        with ps; [
          final.stashapp-tools
          aiohttp
          pydantic
        ]);
    })
  ];

  # Stash media organizer
  services.stash = let
    # Fetch the CommunityScripts repository once
    communityScripts = pkgs.fetchFromGitHub {
      owner = "stashapp";
      repo = "CommunityScripts";
      rev = "eff9999aa884f030701f70dee36711603bab8b6d";
      hash = "sha256-Bx4C1Ms5ziQAQTvdhgvIM4ZlBS3IqWNiJK0VEypKxEA=";
      sparseCheckout = ["plugins"];
    };

    # Helper to create plugin packages
    mkStashPlugin = pluginName:
      pkgs.runCommand "stash-plugin-${pluginName}" {} ''
        mkdir -p $out
        cp -r ${communityScripts}/plugins/${pluginName}/* $out/
      '';

    # Workaround for nixpkgs bug: passwordFile is read unconditionally even when null
    # Create an empty file since we don't want authentication
    emptyPasswordFile = pkgs.writeText "empty-password" "";
  in {
    enable = true;
    openFirewall = true; # Allow access through port 9999
    user = "media";
    group = "media";
    username = "dummy"; # Required by assertion, but empty password = no auth
    passwordFile = emptyPasswordFile; # Dummy file to work around module bug
    jwtSecretKeyFile = config.sops.secrets."stash-jwt-secret".path;
    sessionStoreKeyFile = config.sops.secrets."stash-session-secret".path;
    mutablePlugins = false;
    mutableSettings = false; # Force config.yml regeneration to include plugins_path
    plugins = [
      (mkStashPlugin "CommunityScriptsUILibrary") # UI library used by other community plugins
      (mkStashPlugin "stashAI") # AI-powered features
    ];
    settings = {
      host = "0.0.0.0";
      sequential_scanning = true;
      parallel_tasks = 5;
      stash = [
        {
          path = "/mnt/games/Stash";
        }
      ];
    };
  };

  # Override Stash systemd service to use custom Python with stashapp-tools
  systemd.services.stash = {
    path = lib.mkForce (with pkgs; [
      coreutils # Provides install, env, and other basic utilities
      ffmpeg-full
      stashPython
      ruby
    ]);

    # Configure ffmpeg to use Intel iGPU for hardware video acceleration
    environment = {
      LIBVA_DRIVER_NAME = "iHD"; # Intel media driver for Gen 8+ GPUs
      LIBVA_DEVICE = "/dev/dri/renderD129"; # Intel iGPU render device
    };
  };

  # Configure Docker storage driver
  virtualisation.docker.storageDriver = "overlay2";

  boot = {
    binfmt.emulatedSystems = ["aarch64-linux"];
    binfmt.preferStaticEmulators = true;
  };

  # binfmt lets raider *run* aarch64 binaries, but NixOS also derives
  # nix.settings.extra-platforms from binfmt.emulatedSystems, which makes Nix
  # treat raider as a valid aarch64 builder. Nix prefers a free local slot
  # over a remote builder, and with max-jobs = 16 there almost always is one,
  # so aarch64 derivations get built here under qemu instead of natively on
  # basestar -- which then sits idle. Determinate Nix's functional test suite
  # ran >4h in checkPhase that way and blocked a whole tier-1 deploy.
  # Keep the emulator for running binaries; take aarch64 off the builder list
  # so it goes to basestar. i686-linux is the stock x86_64 default. See #405.
  nix.settings.extra-platforms = lib.mkForce ["i686-linux"];

  # Additional packages
  # Web apps via firefoxpwa (install PWAs from Firefox extension)
  programs.firefox.nativeMessagingHosts.packages = [pkgs.firefoxpwa];

  # Android debugging. programs.adb was removed from nixpkgs: systemd >= 258
  # applies the uaccess udev rules itself, so the device nodes are already
  # reachable by the logged-in user and neither android-udev-rules nor an
  # adbusers group membership is needed. Shipping the binaries is the whole
  # of it now.
  environment.systemPackages = with pkgs; [
    android-tools
    anycubic-slicer
    firefox
    firefoxpwa
    whitesur-gtk-theme
    whitesur-icon-theme
    whitesur-cursors
    apple-cursor
  ];

  # macOS GNOME appearance and shell configuration
  programs.dconf.profiles.user.databases = [
    {
      settings = {
        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          cursor-theme = "WhiteSur-cursors";
          cursor-size = lib.gvariant.mkInt32 24;
        };

        "org/gnome/desktop/wm/preferences" = {
          button-layout = "appmenu:minimize,maximize,close";
        };

        "org/gnome/shell/extensions/user-theme" = {
          name = "WhiteSur-Dark";
        };

        "org/gnome/shell/extensions/Logo-menu" = {
          symbolic-icon = true;
          menu-button-icon-image = lib.gvariant.mkInt32 0; # Apple icon via WhiteSur start-here-symbolic
          menu-button-icon-size = lib.gvariant.mkInt32 20;
          hide-icon-shadow = false;
          menu-button-terminal = "ghostty";
          menu-button-system-monitor = "missioncenter";
          menu-button-extensions-app = "com.mattjakeman.ExtensionManager.desktop";
          menu-button-software-center = "bazaar";
          show-activities-button = true;
          hide-forcequit = true;
          show-lockscreen = false;
          show-power-options = false;
        };

        "org/gnome/shell/extensions/dash-to-dock" = {
          dock-position = "BOTTOM";
          dock-fixed = false;
          autohide = true;
          intellihide = true;
          extend-height = false;
          custom-theme-shrink = true;
          dash-max-icon-size = lib.gvariant.mkInt32 48;
          running-indicator-style = "DOTS";
          show-trash = true;
          show-mounts = false;
          transparency-mode = "DYNAMIC";
          apply-custom-theme = false;
        };

        "org/gnome/shell/extensions/blur-my-shell/dash-to-dock" = {
          blur = true;
          pipeline = "pipeline_default";
        };

        "org/gnome/shell/extensions/blur-my-shell/panel" = {
          blur = true;
          pipeline = "pipeline_default";
        };
      };
    }
  ];

  # Basic system configuration
  networking.hostName = "raider";

  systemd.services.NetworkManager-wait-online.enable = false;

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables = true;

  # Boot appearance
  boot.plymouth.enable = true;
  boot.plymouth.theme = "bgrt";
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;

  # Remove zfs, add nfs for media mount
  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "nfs" "ntfs" "reiserfs" "vfat" "xfs"];

  # Disable aggressive SATA power management to prevent SSD freezing
  boot.kernelParams = ["ahci.mobile_lpm_policy=0"];
  powerManagement.scsiLinkPolicy = "max_performance";

  networking.nftables.enable = true;

  # Additional system services specific to this machine
  # CoolerControl is configured in ./coolercontrol.nix

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

  # Filebrowser - web-based file manager accessible from browser/iPhone
  services.filebrowser = {
    enable = true;
    user = "arosenfeld";
    group = "users";
    settings = {
      address = "0.0.0.0";
      port = 8080;
      root = "/home/arosenfeld";
    };
  };

  # Disable firewall for development
  networking.firewall.enable = false;

  # Disable suspend/hibernate
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandlePowerKey = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    IdleAction = "ignore";
    IdleActionSec = 0;
  };

  # Mask the sleep units entirely: any Suspend() DBus call (desktop session,
  # GDM greeter, systemctl) fails instead of sleeping. logind IdleAction=ignore
  # and the dconf policies below don't cover every caller.
  systemd.services = {
    systemd-suspend.enable = false;
    systemd-hibernate.enable = false;
    systemd-hybrid-sleep.enable = false;
    systemd-suspend-then-hibernate.enable = false;
  };
  systemd.targets = {
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
    sleep.enable = false;
  };

  # Disable power management features
  powerManagement = {
    enable = true;
    powertop.enable = false; # Disabled - causes aggressive power management that freezes input
  };

  # Prevent the GDM greeter's gnome-settings-daemon from issuing an idle
  # Suspend() DBus call after 15 min (logind IdleAction=ignore doesn't block
  # explicit DBus suspends — only the greeter's dconf policy does).
  programs.dconf.profiles.gdm.databases = [
    {
      settings."org/gnome/settings-daemon/plugins/power" = {
        sleep-inactive-ac-type = "nothing";
        sleep-inactive-ac-timeout = lib.gvariant.mkInt32 0;
        sleep-inactive-battery-type = "nothing";
        sleep-inactive-battery-timeout = lib.gvariant.mkInt32 0;
      };
    }
  ];

  # Environment variables for games
  environment.sessionVariables = {
    GAMES_DIR = "/mnt/games";
    # `just deploy` phase 1 pushes through nix-fast-build --niks3-server,
    # whose upload worker runs `niks3 push` as this user. Pointing it at the
    # sops secret keeps a single copy of the token on disk.
    NIKS3_AUTH_TOKEN_FILE = config.sops.secrets."niks3-api-token".path;
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  system.stateVersion = "23.05";
}
