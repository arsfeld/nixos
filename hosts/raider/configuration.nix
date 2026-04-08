{
  self,
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ./disko-config.nix
    ./btrbk.nix
    ./fan-control.nix
    ./fontconfig.nix
    ./harmonia.nix
    ./samba.nix
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

  # Allow insecure packages
  nixpkgs.config.permittedInsecurePackages = [
    "mbedtls-2.28.10"
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
    niri.enable = false;
    cosmic.enable = false;
    gaming = {
      enable = true;
      cpuVendor = "intel";
    };
    development.enable = true;
    docker.enable = true; # Enable Docker runtime
    backup.enable = true; # Enable automated backups
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
          aiohttp # Required by AITagger plugin
          pydantic # Required by AITagger plugin
          imageio # Required by AITagger plugin (base package)
          imageio-ffmpeg # Required by AITagger plugin (ffmpeg extra)
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
      (mkStashPlugin "AITagger") # AI-based tagging
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
  };

  # Additional packages
  # Web apps via firefoxpwa (install PWAs from Firefox extension)
  programs.firefox.nativeMessagingHosts.packages = [pkgs.firefoxpwa];

  environment.systemPackages = with pkgs; [
    anycubic-slicer
    firefox
    firefoxpwa
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

  # Disable power management features
  powerManagement = {
    enable = true;
    powertop.enable = false; # Disabled - causes aggressive power management that freezes input
  };

  # Disable GNOME auto-suspend
  services.displayManager.gdm.autoSuspend = false;

  # Environment variables for games
  environment.sessionVariables = {
    GAMES_DIR = "/mnt/games";
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  system.stateVersion = "23.05";
}
