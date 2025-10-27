{
  self,
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
    ./scheduler-tuning.nix
  ];

  # Age secrets for Stash
  age.secrets."stash-jwt-secret" = {
    file = "${self}/secrets/stash-jwt-secret.age";
  };
  age.secrets."stash-session-secret" = {
    file = "${self}/secrets/stash-session-secret.age";
  };
  age.secrets."stash-password" = {
    file = "${self}/secrets/stash-password.age";
  };

  # Allow insecure packages
  nixpkgs.config.permittedInsecurePackages = [
    "mbedtls-2.28.10"
  ];

  # Enable constellation modules
  constellation = {
    gnome.enable = true;
    gaming.enable = true;
    development.enable = true;
    docker.enable = true; # Enable Docker runtime
    backup.enable = true; # Enable automated backups
    services.enable = true; # Enable service gateway for harmonia tsnsrv integration
  };

  # Enable media config for domain settings (required by constellation.services)
  media.config.enable = true;

  # Stash media organizer
  services.stash = {
    enable = true;
    openFirewall = true; # Allow access through port 9999
    username = "admin";
    passwordFile = "/run/agenix/stash-password";
    jwtSecretKeyFile = "/run/agenix/stash-jwt-secret";
    sessionStoreKeyFile = "/run/agenix/stash-session-secret";
    settings = {
      stash = [
        {
          path = "/mnt/media/stash";
        }
      ];
    };
  };

  # Configure Docker storage driver
  virtualisation.docker.storageDriver = "overlay2";

  boot = {
    binfmt.emulatedSystems = ["aarch64-linux"];
  };

  # Additional packages
  environment.systemPackages = with pkgs; [
    anycubic-slicer
  ];

  # Basic system configuration
  networking.hostName = "raider";

  systemd.services.NetworkManager-wait-online.enable = false;

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Boot appearance
  boot.plymouth.enable = true;
  boot.plymouth.theme = "bgrt";
  boot.initrd.verbose = false;
  boot.consoleLogLevel = 0;

  # Remove zfs
  boot.supportedFilesystems = lib.mkForce ["btrfs" "cifs" "f2fs" "jfs" "ntfs" "reiserfs" "vfat" "xfs" "bcachefs"];

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

  # Disable firewall for development
  networking.firewall.enable = false;

  # Disable suspend/hibernate
  services.logind = {
    lidSwitch = "ignore";
    lidSwitchDocked = "ignore";
    lidSwitchExternalPower = "ignore";
    extraConfig = ''
      HandlePowerKey=ignore
      HandleSuspendKey=ignore
      HandleHibernateKey=ignore
      IdleAction=ignore
      IdleActionSec=0
    '';
  };

  # Disable power management features
  powerManagement = {
    enable = true;
    powertop.enable = false; # Disabled - causes aggressive power management that freezes input
  };

  # Disable GNOME auto-suspend
  services.xserver.displayManager.gdm.autoSuspend = false;

  # System activation script for games directory
  system.activationScripts.gamesSetup = ''
    if [ -d /mnt/games ]; then
      mkdir -p /mnt/games/SteamLibrary
      chown -R arosenfeld:users /mnt/games 2>/dev/null || true
      chmod 755 /mnt/games

      if [ ! -L /home/arosenfeld/Games ]; then
        ln -sf /mnt/games /home/arosenfeld/Games 2>/dev/null || true
      fi
    fi
  '';

  # System activation script for Stash media directory
  system.activationScripts.stashMediaSetup = ''
    mkdir -p /mnt/media/stash
    chown -R stash:stash /mnt/media/stash 2>/dev/null || true
    chmod 755 /mnt/media/stash
  '';

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
