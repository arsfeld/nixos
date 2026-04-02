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

    wallpapers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install curated wallpaper collections (NixOS artwork, Fedora, Pop!_OS)";
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
        "com.mattjakeman.ExtensionManager"
      ];
      description = "Flatpak packages to install";
    };
  };

  config = lib.mkIf config.constellation.gnome.enable (let
    # Create unstable package set
    pkgs-unstable = import inputs.nixpkgs-unstable {
      system = pkgs.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };
  in {
    # GNOME Desktop Environment
    services.xserver.enable = true;
    services.displayManager.gdm.enable = true;
    services.desktopManager.gnome.enable = true;

    # Theme and application settings
    programs.dconf.enable = true;
    programs.dconf.profiles.user.databases = [
      {
        settings = {
          # Global theme settings
          "org/gnome/desktop/interface" = {
            gtk-theme = config.constellation.gnome.theme.gtk;
            icon-theme = config.constellation.gnome.theme.icon;
            enable-hot-corners = false;
          };

          # Mutter: VRR, fractional scaling, center new windows
          "org/gnome/mutter" = {
            experimental-features = ["variable-refresh-rate" "scale-monitor-framebuffer"];
            center-new-windows = true;
          };

          # Window management: Alt+Tab switches windows, Super+Tab switches apps
          "org/gnome/desktop/wm/keybindings" = {
            switch-applications = ["<Super>Tab"];
            switch-applications-backward = ["<Shift><Super>Tab"];
            switch-windows = ["<Alt>Tab"];
            switch-windows-backward = ["<Shift><Alt>Tab"];
          };

          # Window decorations: minimize + maximize + close buttons
          "org/gnome/desktop/wm/preferences" = {
            button-layout = "appmenu:minimize,maximize,close";
          };

          # Nautilus: list view, create link option
          "org/gnome/nautilus/preferences" = {
            default-folder-viewer = "list-view";
            show-create-link = true;
          };
          "org/gnome/nautilus/gtk" = {
            application-prefer-dark-theme = true;
          };

          # File chooser: directories first
          "org/gtk/Settings/FileChooser" = {
            sort-directories-first = true;
          };
          "org/gtk/gtk4/Settings/FileChooser" = {
            sort-directories-first = true;
          };

          # Custom keyboard shortcuts
          "org/gnome/settings-daemon/plugins/media-keys" = {
            custom-keybindings = [
              "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
              "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
            ];
          };
          "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
            name = "Terminal";
            command = "ghostty";
            binding = "<Control><Alt>t";
          };
          "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1" = {
            name = "Mission Center";
            command = "missioncenter";
            binding = "<Control><Shift>Escape";
          };

          # Auto-enable GNOME extensions
          "org/gnome/shell" = {
            enabled-extensions = [
              "logomenu@aryan_k"
              "hotedge@jonathan.jdoda.ca"
              "caffeine@patapon.info"
              "compiz-alike-magic-lamp-effect@hermes83.github.com"
              "paperwm@paperwm.github.com"
              "appindicatorsupport@rgcjonas.gmail.com"
              "blur-my-shell@aunetx"
              "dash-to-dock@micxgx.gmail.com"
              "azwallpaper@azwallpaper.gitlab.com"
              "gsconnect@andyholmes.github.io"
              "xwayland-indicator@swsnr.de"
              "Vitals@CoreCoding.com"
              "user-theme@gnome-shell-extensions.gcampax.github.com"
            ];
          };

          # Logo Menu extension configuration
          "org/gnome/shell/extensions/logo-menu" = {
            menu-button-terminal = "ghostty";
            menu-button-system-monitor = "missioncenter";
            menu-button-extensions-app = "com.mattjakeman.ExtensionManager.desktop";
            menu-button-software-center = "bazaar";
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

    # Disable GNOME Software (replaced by Bazaar flatpak)
    services.gnome.gnome-software.enable = false;

    # Remove unwanted GNOME apps
    environment.gnome.excludePackages = with pkgs; [
      gnome-music
      gnome-photos
      gnome-tour
      gnome-console
      gnome-terminal
      gnome-system-monitor
      gnome-software
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
        # Hide built-in GNOME Extensions app (replaced by Extension Manager flatpak)
        (writeTextDir "share/applications/org.gnome.Extensions.desktop" ''
          [Desktop Entry]
          Type=Application
          Name=Extensions
          NoDisplay=true
        '')

        # Core applications
        pkgs-unstable.zed-editor
        pkgs-unstable.ghostty
        localsend
        vim
        wget
        celluloid
        mission-center
        variety
        gnome-tweaks
      ]
      ++ lib.optionals config.constellation.gnome.gnomeExtensions [
        # GNOME extensions
        gnomeExtensions.appindicator
        gnomeExtensions.blur-my-shell
        gnomeExtensions.dash-to-dock
        gnomeExtensions.wallpaper-slideshow
        gnomeExtensions.gsconnect
        gnomeExtensions.xwayland-indicator
        gnomeExtensions.vitals
        gnomeExtensions.user-themes
        gnomeExtensions.logo-menu
        gnomeExtensions.hot-edge
        gnomeExtensions.caffeine
        gnomeExtensions.compiz-alike-magic-lamp-effect
        gnomeExtensions.paperwm

        # Theming
        yaru-theme
        colloid-icon-theme
        colloid-gtk-theme
        pantheon.elementary-sound-theme
        pantheon.elementary-gtk-theme
        pantheon.elementary-icon-theme
      ]
      ++ lib.optionals config.constellation.gnome.gaming [
        # Gaming support
        wineWowPackages.stable
        gamescope
        goverlay
        vkbasalt
        protonplus
        ryubing
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
      ]
      ++ lib.optionals config.constellation.gnome.wallpapers [
        # Curated wallpaper collections
        # NixOS artwork - Catppuccin themes
        nixos-artwork.wallpapers.catppuccin-mocha
        nixos-artwork.wallpapers.catppuccin-macchiato
        nixos-artwork.wallpapers.catppuccin-frappe
        nixos-artwork.wallpapers.catppuccin-latte
        # NixOS artwork - 3D designs
        nixos-artwork.wallpapers.gear
        nixos-artwork.wallpapers.moonscape
        nixos-artwork.wallpapers.recursive
        nixos-artwork.wallpapers.waterfall
        nixos-artwork.wallpapers.watersplash
        # NixOS artwork - Other themes
        nixos-artwork.wallpapers.dracula
        nixos-artwork.wallpapers.nineish
        nixos-artwork.wallpapers.nineish-dark-gray
        nixos-artwork.wallpapers.mosaic-blue
        # Fedora backgrounds (high-quality professional wallpapers)
        fedora-backgrounds.f38
        fedora-backgrounds.f37
        fedora-backgrounds.f36
        # Landscape photography collections
        budgie-backgrounds
        fedora-backgrounds.f32
        # Elementary wallpapers (no GNOME XML, available for slideshow/manual)
        pantheon.elementary-wallpapers
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
        ubuntu-classic
        cantarell-fonts

        # Nerd fonts for terminal use
        nerd-fonts.fira-code
        nerd-fonts.jetbrains-mono
        nerd-fonts.meslo-lg

        # Essential fonts
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-color-emoji
        liberation_ttf
        dejavu_fonts
        freefont_ttf

        # Japanese fonts (source-han-sans/serif now include all variants)
        source-han-sans
        source-han-serif

        # Microsoft-compatible fonts
        corefonts
        vista-fonts

        # Programming fonts
        cascadia-code
        iosevka
        fira-code
      ];
    };
  });
}
