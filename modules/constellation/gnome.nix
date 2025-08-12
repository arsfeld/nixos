# Desktop environment configuration for constellation
# Provides GNOME desktop with essential applications
{
  config,
  pkgs,
  lib,
  ...
}: {
  options.constellation.gnome = {
    enable = lib.mkEnableOption "GNOME desktop environment";

    gnomeExtensions = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install GNOME extensions and tweaks";
    };
  };

  config = lib.mkIf config.constellation.gnome.enable {
    # GNOME Desktop Environment
    services.xserver = {
      enable = true;

      # Display Manager
      displayManager.gdm = {
        enable = true;
        wayland = true;
      };

      # Desktop Manager
      desktopManager.gnome.enable = true;
    };

    # Remove unwanted GNOME apps
    environment.gnome.excludePackages = with pkgs; [
      gnome-tour
      epiphany
      geary
      gnome-music
      gnome-contacts
      gnome-maps
      gnome-weather
      gnome-photos
      gnome-console
      gnome-terminal
      gnome-system-monitor
      evince
      totem
      tali
      hitori
      atomix
      iagno
    ];

    # Essential desktop packages
    environment.systemPackages = with pkgs;
      [
        # GNOME essentials
        gnome-tweaks
        gnome-extension-manager

        # Terminal
        gnome-console

        # File management
        file-roller

        # Media
        celluloid
        gnome-software
      ]
      ++ lib.optionals config.constellation.gnome.gnomeExtensions [
        # GNOME extensions
        gnomeExtensions.appindicator
        gnomeExtensions.dash-to-dock
        gnomeExtensions.blur-my-shell
        gnomeExtensions.vitals
        gnomeExtensions.tiling-assistant
        gnomeExtensions.pop-shell
        gnomeExtensions.gsconnect
        gnomeExtensions.user-themes

        # Theming
        yaru-theme
        colloid-icon-theme
        colloid-gtk-theme
      ];

    # Hardware graphics support
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    # Flatpak support
    services.flatpak.enable = true;

    # Disable network manager wait
    systemd.services.NetworkManager-wait-online.enable = false;

    # Printing support
    services.printing = {
      enable = true;
      drivers = with pkgs; [hplipWithPlugin samsung-unified-linux-driver];
    };

    # Network discovery
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };

    # Font configuration
    fonts = {
      fontconfig = {
        antialias = true;
        cache32Bit = true;
        hinting.enable = true;
        hinting.autohint = true;
      };

      packages = with pkgs; [
        nerd-fonts.fira-code
        nerd-fonts.droid-sans-mono
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-emoji
        liberation_ttf
        cascadia-code
      ];
    };
  };
}
