# Desktop environment configuration for constellation
# Provides GNOME desktop with essential applications, gaming support, and multimedia
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  options.constellation.gnome = {
    enable = lib.mkEnableOption "GNOME desktop environment with full desktop stack";

    theme = lib.mkOption {
      type = lib.types.submodule {
        options = {
          gtk = lib.mkOption {
            type = lib.types.str;
            default = "Adwaita-dark";
            description = "GTK theme name";
          };
          icon = lib.mkOption {
            type = lib.types.str;
            default = "Adwaita";
            description = "Icon theme name";
          };
        };
      };
      default = {};
      description = "Theme configuration for GNOME";
    };

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
        "io.github.kolunmi.Bazaar"
      ];
      description = "Flatpak packages to install";
    };
  };

  config = lib.mkIf config.constellation.gnome.enable (let
    # Create unstable package set
    pkgs-unstable = import inputs.nixpkgs-unstable {
      inherit (pkgs) system;
      config.allowUnfree = true;
    };
  in {
    # GNOME Desktop Environment
    services.xserver = {
      enable = true;
      displayManager.gdm.enable = true;
      desktopManager.gnome.enable = true;
    };

    # Theme and application settings
    programs.dconf.enable = true;
    programs.dconf.profiles.user.databases = [
      {
        settings = {
          # Global theme settings
          "org/gnome/desktop/interface" = {
            gtk-theme = config.constellation.gnome.theme.gtk;
            icon-theme = config.constellation.gnome.theme.icon;
          };

          # Enable variable refresh rate (VRR) support
          "org/gnome/mutter" = {
            experimental-features = ["variable-refresh-rate" "scale-monitor-framebuffer"];
          };

          # Dark mode for Nautilus (Files)
          "org/gnome/nautilus/preferences" = {
            default-folder-viewer = "list-view";
          };
          "org/gnome/nautilus/gtk" = {
            application-prefer-dark-theme = true;
          };

          # Dark mode for Ptyxis (Console)
          "app/devsuite/Ptyxis" = {
            prefer-dark-theme = true;
          };

          # Dark mode for Zen Browser
          "app/zen-browser/zen" = {
            prefer-dark-theme = true;
          };
        };
      }
    ];

    # Disable network manager wait
    systemd.services.NetworkManager-wait-online.enable = false;

    # Hardware graphics support with 32-bit compatibility
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [];
      extraPackages32 = with pkgs; [];
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
        pkgs-unstable.zed-editor
        vim
        wget
        ghostty
        celluloid
        mission-center
        variety
        gradience
        gnome-tweaks
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
        vkbasalt
        protonplus
        ryujinx
        mupen64plus
        rpcs3
      ]
      ++ lib.optionals config.constellation.gnome.multimedia [
        # Multimedia support
        plex-mpv-shim
        pkgs-unstable.multiviewer-for-f1
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

    # Font configuration with improved rendering
    fonts = {
      fontconfig = {
        enable = true;
        antialias = true;
        cache32Bit = true;
        hinting = {
          enable = true;
          autohint = false; # Disable autohint for better quality with modern fonts
          style = "slight"; # Use slight hinting for better appearance
        };
        subpixel = {
          rgba = "none"; # Standard antialiasing without subpixel rendering
          lcdfilter = "none"; # No LCD filter needed for standard antialiasing
        };
        defaultFonts = {
          serif = ["Noto Serif" "Liberation Serif" "DejaVu Serif"];
          sansSerif = ["Inter" "Noto Sans" "DejaVu Sans"];
          monospace = ["JetBrains Mono" "Cascadia Code" "Fira Code"];
          emoji = ["Noto Color Emoji"];
        };
      };

      packages = with pkgs; [
        # High-quality font families
        inter
        jetbrains-mono
        roboto
        ubuntu_font_family
        cantarell-fonts

        # Nerd fonts for terminal use
        nerd-fonts.fira-code
        nerd-fonts.jetbrains-mono
        nerd-fonts.meslo-lg

        # Essential fonts
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-emoji
        liberation_ttf
        dejavu_fonts
        freefont_ttf

        # Japanese fonts
        source-han-sans
        source-han-serif
        source-han-sans-japanese
        source-han-serif-japanese

        # Microsoft-compatible fonts
        corefonts
        vistafonts

        # Programming fonts
        cascadia-code
        iosevka
        fira-code
      ];
    };
  });
}
