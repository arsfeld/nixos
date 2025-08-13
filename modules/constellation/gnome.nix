# Desktop environment configuration for constellation
# Provides GNOME desktop with essential applications, gaming support, and multimedia
{
  config,
  pkgs,
  lib,
  ...
}: {
  options.constellation.gnome = {
    enable = lib.mkEnableOption "GNOME desktop environment with full desktop stack";

    gnomeExtensions = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install GNOME extensions and tweaks";
    };

    gaming = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable gaming support (Steam, Wine, emulators, game launchers)";
    };

    multimedia = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable multimedia codecs and GStreamer plugins";
    };

    virtualization = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable virtualization tools (virt-manager, quickemu)";
    };

    flatpakPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "com.valvesoftware.Steam"
        "com.github.tchx84.Flatseal"
        "com.spotify.Client"
        "tv.plex.PlexDesktop"
        "org.mozilla.firefox"
        "com.discordapp.Discord"
        "org.libreoffice.LibreOffice"
        "engineer.atlas.Nyxt"
        # "com.visualstudio.code"  # Disabled - ar command fails with missing libsframe.so.1
        "org.videolan.VLC"
        "com.usebottles.bottles"
        "net.lutris.Lutris"
        "app.devsuite.Ptyxis"
        "app.zen_browser.zen"
      ];
      description = "Flatpak packages to install";
    };
  };

  config = lib.mkIf config.constellation.gnome.enable {
    # GNOME Desktop Environment
    services.xserver = {
      enable = true;
      displayManager.gdm.enable = true;
      desktopManager.gnome.enable = true;
    };

    # Disable network manager wait
    systemd.services.NetworkManager-wait-online.enable = false;

    # Hardware graphics support with 32-bit compatibility
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [mangohud];
      extraPackages32 = with pkgs; [mangohud];
    };

    # Remove unwanted GNOME apps
    environment.gnome.excludePackages = with pkgs; [
      gnome-music
      gnome-photos
      gnome-tour
      gnome-console
      gnome-terminal
      gnome-system-monitor
      geary
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
        # Core applications
        zed-editor
        vim
        wget
        ghostty
        celluloid
        mission-center
        variety
        gradience
        gnome-tweaks
        # Bazaar - GNOME app store for Flatpak
        bazaar
      ]
      ++ lib.optionals config.constellation.gnome.gnomeExtensions [
        # GNOME extensions
        gnomeExtensions.appindicator
        gnomeExtensions.blur-my-shell
        gnomeExtensions.dash-to-dock
        gnomeExtensions.wallpaper-slideshow
        gnomeExtensions.gsconnect
        gnomeExtensions.gtile
        gnomeExtensions.xwayland-indicator
        gnomeExtensions.vitals
        gnomeExtensions.window-gestures
        gnomeExtensions.user-themes
        gnomeExtensions.tiling-shell

        # Theming
        yaru-theme
        colloid-icon-theme
        colloid-gtk-theme
        pantheon.elementary-sound-theme
        pantheon.elementary-gtk-theme
        pantheon.elementary-icon-theme
        pantheon.elementary-wallpapers
      ]
      ++ lib.optionals config.constellation.gnome.gaming [
        # Gaming support
        wineWowPackages.stable
        gamescope
        goverlay
        mangohud
        vkbasalt
        protonplus
        ryujinx
        mupen64plus
        rpcs3
      ]
      ++ lib.optionals config.constellation.gnome.multimedia [
        # Multimedia support
        plex-mpv-shim
        multiviewer-for-f1
        # GStreamer plugins
        gst_all_1.gstreamer
        gst_all_1.gst-plugins-base
        gst_all_1.gst-plugins-good
        gst_all_1.gst-plugins-bad
        gst_all_1.gst-plugins-ugly
        gst_all_1.gst-libav
        gst_all_1.gst-vaapi
      ]
      ++ lib.optionals config.constellation.gnome.virtualization [
        # Virtualization tools
        quickemu
      ];

    # Gaming hardware support
    hardware.steam-hardware.enable = lib.mkIf config.constellation.gnome.gaming true;

    # Virtual machine management
    programs.virt-manager.enable = lib.mkIf config.constellation.gnome.virtualization true;

    # Flatpak support with configured packages
    services.flatpak = {
      enable = true;
      packages = config.constellation.gnome.flatpakPackages;
    };

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
        source-han-sans-japanese
        source-han-serif-japanese
        cascadia-code
      ];
    };
  };
}
