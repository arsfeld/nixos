# Niri Wayland compositor configuration for constellation
# Provides a scrollable-tiling Wayland compositor with GNOME-like defaults
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  options.constellation.niri = {
    enable = lib.mkEnableOption "Niri scrollable-tiling Wayland compositor";

    terminal = lib.mkOption {
      type = lib.types.str;
      default = "ghostty";
      description = "Default terminal emulator command";
    };

    launcher = lib.mkOption {
      type = lib.types.str;
      default = "fuzzel";
      description = "Application launcher command";
    };

    wallpaper = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to wallpaper image. If null, uses swaybg with default";
    };

    useGdm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use GDM instead of greetd for display manager";
    };

    includeGnomeApps = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include GNOME applications (Nautilus, Calculator, etc.)";
    };

    gaming = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable gaming support (Steam, Wine, gamescope)";
    };

    multimedia = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable multimedia codecs and GStreamer plugins";
    };

    wallpapers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install curated wallpaper collections";
    };

    flatpakPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "com.github.tchx84.Flatseal"
        "com.spotify.Client"
        "org.mozilla.firefox"
        "com.discordapp.Discord"
        "org.videolan.VLC"
        "app.zen_browser.zen"
      ];
      description = "Flatpak packages to install";
    };
  };

  config = lib.mkIf config.constellation.niri.enable (let
    cfg = config.constellation.niri;
    # Create unstable package set
    pkgs-unstable = import inputs.nixpkgs-unstable {
      system = pkgs.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };
  in {
    # Enable niri compositor
    programs.niri.enable = true;

    # Display manager configuration
    services.xserver.enable = true;

    # GDM or greetd
    services.displayManager.gdm = lib.mkIf cfg.useGdm {
      enable = true;
      wayland = true;
    };

    services.greetd = lib.mkIf (!cfg.useGdm) {
      enable = true;
      settings = {
        default_session = {
          command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --remember-session --cmd niri-session";
          user = "greeter";
        };
      };
    };

    # Security and authentication
    security.polkit.enable = true;
    services.gnome.gnome-keyring.enable = true;
    security.pam.services.swaylock = {};

    # Enable dconf for GNOME settings
    programs.dconf.enable = true;

    # XDG portals for file dialogs, screen sharing, etc.
    xdg.portal = {
      enable = true;
      extraPortals = with pkgs; [
        xdg-desktop-portal-gtk
        xdg-desktop-portal-gnome
      ];
      config.niri = {
        default = ["gtk"];
        "org.freedesktop.impl.portal.FileChooser" = ["gtk"];
        "org.freedesktop.impl.portal.Secret" = ["gnome-keyring"];
      };
    };

    # Environment variables for Wayland
    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1"; # Electron apps Wayland support
      MOZ_ENABLE_WAYLAND = "1"; # Firefox Wayland
      QT_QPA_PLATFORM = "wayland;xcb"; # Qt apps
      SDL_VIDEODRIVER = "wayland"; # SDL apps
      _JAVA_AWT_WM_NONREPARENTING = "1"; # Java apps
    };

    # Hardware graphics support
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    # Audio with PipeWire (GNOME default)
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;
    };
    security.rtkit.enable = true; # For PipeWire realtime scheduling

    # Bluetooth support
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
    services.blueman.enable = true;

    # Network manager
    networking.networkmanager.enable = true;

    # Printing support
    services.printing = {
      enable = true;
      drivers = with pkgs; [hplipWithPlugin];
    };

    # Network discovery
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };

    # Disable network manager wait
    systemd.services.NetworkManager-wait-online.enable = false;

    # Essential packages
    environment.systemPackages = with pkgs;
      [
        # Core compositor utilities
        xwayland-satellite # XWayland support for legacy apps
        wl-clipboard # Clipboard support
        cliphist # Clipboard history

        # Terminal
        pkgs-unstable.ghostty
        alacritty # Backup terminal

        # Application launcher - anyrun for polished look
        anyrun
        fuzzel # Backup launcher

        # Bar and widgets - eww for declarative configuration
        eww

        # Notifications
        mako
        libnotify

        # Screen locking and idle
        swaylock
        swayidle
        swaylock-effects # Fancy lock screen

        # Wallpaper
        swaybg
        waypaper # GUI wallpaper picker

        # Screenshot and screen recording
        grim # Screenshot
        slurp # Region selection
        swappy # Screenshot annotation
        wf-recorder # Screen recording
        wl-screenrec # Alternative screen recorder

        # Audio control
        pavucontrol
        playerctl
        pamixer

        # Brightness control
        brightnessctl
        wlsunset # Night light / blue light filter

        # Polkit authentication agent
        polkit_gnome

        # File manager
        xfce.thunar
        xfce.thunar-volman
        xfce.thunar-archive-plugin

        # System utilities
        networkmanagerapplet
        blueman

        # Themes and appearance - WhiteSur macOS style
        whitesur-gtk-theme
        whitesur-icon-theme
        whitesur-cursors
        adwaita-icon-theme
        gnome-themes-extra
        hicolor-icon-theme

        # Core applications
        pkgs-unstable.zed-editor
        vim
        wget
      ]
      ++ lib.optionals cfg.includeGnomeApps [
        # GNOME applications
        nautilus
        gnome-calculator
        gnome-calendar
        gnome-characters
        gnome-clocks
        gnome-contacts
        gnome-disk-utility
        gnome-font-viewer
        gnome-system-monitor
        gnome-weather
        gnome-control-center
        loupe # Image viewer
        evince # Document viewer
        file-roller # Archive manager
        baobab # Disk usage analyzer
        gnome-text-editor
        seahorse # Password manager
        gnome-settings-daemon
      ]
      ++ lib.optionals cfg.gaming [
        # Gaming support
        wineWowPackages.stable
        gamescope
        goverlay
        vkbasalt
        protonplus
      ]
      ++ lib.optionals cfg.multimedia [
        # Multimedia support
        celluloid # Video player
        gst_all_1.gstreamer
        gst_all_1.gst-plugins-base
        gst_all_1.gst-plugins-good
        gst_all_1.gst-plugins-bad
        gst_all_1.gst-plugins-ugly
        gst_all_1.gst-libav
        gst_all_1.gst-vaapi
      ]
      ++ lib.optionals cfg.wallpapers [
        # Wallpaper collections
        nixos-artwork.wallpapers.catppuccin-mocha
        nixos-artwork.wallpapers.catppuccin-macchiato
        nixos-artwork.wallpapers.gear
        nixos-artwork.wallpapers.moonscape
        nixos-artwork.wallpapers.nineish-dark-gray
        fedora-backgrounds.f38
        pop-hp-wallpapers
      ];

    # Gaming hardware support
    hardware.steam-hardware.enable = lib.mkIf cfg.gaming true;

    # Flatpak support
    services.flatpak = {
      enable = true;
      packages = cfg.flatpakPackages;
    };

    # Font configuration (same as GNOME module)
    fonts = {
      fontconfig = {
        enable = true;
        antialias = true;
        cache32Bit = true;
        hinting = {
          enable = true;
          autohint = false;
          style = "slight";
        };
        subpixel = {
          rgba = "none";
          lcdfilter = "none";
        };
        defaultFonts = {
          serif = ["Noto Serif" "Liberation Serif" "DejaVu Serif"];
          sansSerif = ["Inter" "Noto Sans" "DejaVu Sans"];
          monospace = ["JetBrains Mono" "Cascadia Code" "Fira Code"];
          emoji = ["Noto Color Emoji"];
        };
      };

      packages = with pkgs; [
        inter
        jetbrains-mono
        roboto
        ubuntu-classic
        cantarell-fonts
        nerd-fonts.fira-code
        nerd-fonts.jetbrains-mono
        nerd-fonts.meslo-lg
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-color-emoji
        liberation_ttf
        dejavu_fonts
        freefont_ttf
        source-han-sans
        source-han-serif
        corefonts
        cascadia-code
        iosevka
        fira-code
      ];
    };

    # dconf settings for GNOME apps and dark mode - WhiteSur macOS theme
    programs.dconf.profiles.user.databases = [
      {
        settings = {
          "org/gnome/desktop/interface" = {
            color-scheme = "prefer-dark";
            gtk-theme = "WhiteSur-Dark";
            icon-theme = "WhiteSur-dark";
            cursor-theme = "WhiteSur-cursors";
            cursor-size = lib.gvariant.mkInt32 24;
          };
          "org/gnome/desktop/wm/preferences" = {
            button-layout = "close,minimize,maximize:";
          };
        };
      }
    ];

    # Enable GVFS for mounting removable media in file managers
    services.gvfs.enable = true;
    services.udisks2.enable = true;

    # Thumbnail generation
    services.tumbler.enable = true;
  });
}
