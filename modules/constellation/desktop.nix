# Unified desktop environment configuration for constellation
#
# Selects between GNOME, COSMIC, and Niri via constellation.desktop.variant.
# All variants share the same user-facing UX: same flatpaks, terminal (ghostty),
# editor (zed), fonts, printers, multimedia codecs, wallpapers, and virtualization
# tooling. Variant only chooses the compositor/shell layer.
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  cfg = config.constellation.desktop;
in {
  options.constellation.desktop = {
    enable = lib.mkEnableOption "desktop environment";

    variant = lib.mkOption {
      type = lib.types.enum ["gnome" "cosmic" "niri"];
      description = "Desktop environment variant to install";
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
        "org.videolan.VLC"
        "com.usebottles.bottles"
        "net.lutris.Lutris"
        "app.devsuite.Ptyxis"
        "app.zen_browser.zen"
        "io.github.kolunmi.Bazaar"
        "com.mattjakeman.ExtensionManager"
      ];
      description = "Flatpak packages to install (shared across all variants)";
    };

    gnome = {
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
        description = "GNOME theme configuration";
      };

      extensions = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install GNOME extensions and tweaks";
      };
    };

    niri = {
      useGdm = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Use GDM instead of greetd for Niri display manager";
      };

      includeGnomeApps = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Include GNOME applications (Nautilus, Calculator, etc.) on Niri";
      };

      gaming = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable gaming support on Niri (Steam, Wine, gamescope)";
      };
    };
  };

  config = lib.mkIf cfg.enable (let
    pkgs-unstable = import inputs.nixpkgs-unstable {
      system = pkgs.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };
  in
    lib.mkMerge [
      # ======== SHARED BASE (every variant) ========
      {
        hardware.graphics = {
          enable = true;
          enable32Bit = true;
        };

        systemd.services.NetworkManager-wait-online.enable = false;

        services.flatpak = {
          enable = true;
          packages = cfg.flatpakPackages;
        };

        services.printing = {
          enable = true;
          drivers = with pkgs; [hplipWithPlugin samsung-unified-linux-driver];
        };

        services.avahi = {
          enable = true;
          nssmdns4 = true;
          openFirewall = true;
        };

        programs.virt-manager.enable = lib.mkIf cfg.virtualization true;

        environment.systemPackages = with pkgs;
          [
            pkgs-unstable.zed-editor
            pkgs-unstable.ghostty
            localsend
            mission-center
            variety
            vim
            wget
          ]
          ++ lib.optionals cfg.multimedia [
            celluloid
            plex-mpv-shim
            pkgs-unstable.multiviewer-for-f1
            gst_all_1.gstreamer
            gst_all_1.gst-plugins-base
            gst_all_1.gst-plugins-good
            gst_all_1.gst-plugins-bad
            gst_all_1.gst-plugins-ugly
            gst_all_1.gst-libav
            gst_all_1.gst-vaapi
          ]
          ++ lib.optionals cfg.virtualization [
            quickemu
          ]
          ++ lib.optionals cfg.wallpapers [
            nixos-artwork.wallpapers.catppuccin-mocha
            nixos-artwork.wallpapers.catppuccin-macchiato
            nixos-artwork.wallpapers.catppuccin-frappe
            nixos-artwork.wallpapers.catppuccin-latte
            nixos-artwork.wallpapers.gear
            nixos-artwork.wallpapers.moonscape
            nixos-artwork.wallpapers.recursive
            nixos-artwork.wallpapers.waterfall
            nixos-artwork.wallpapers.watersplash
            nixos-artwork.wallpapers.dracula
            nixos-artwork.wallpapers.nineish
            nixos-artwork.wallpapers.nineish-dark-gray
            nixos-artwork.wallpapers.mosaic-blue
            fedora-backgrounds.f38
            fedora-backgrounds.f37
            fedora-backgrounds.f36
            fedora-backgrounds.f32
            budgie-backgrounds
            pantheon.elementary-wallpapers
          ];

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
            vista-fonts
            cascadia-code
            iosevka
            fira-code
          ];
        };
      }

      # ======== GNOME VARIANT ========
      (lib.mkIf (cfg.variant == "gnome") {
        services.xserver.enable = true;
        services.displayManager.gdm.enable = true;
        services.desktopManager.gnome.enable = true;
        services.gnome.gnome-software.enable = false;

        programs.dconf.enable = true;
        programs.dconf.profiles.user.databases = [
          {
            settings = {
              "org/gnome/desktop/interface" = {
                gtk-theme = cfg.gnome.theme.gtk;
                icon-theme = cfg.gnome.theme.icon;
                enable-hot-corners = false;
              };

              "org/gnome/mutter" = {
                experimental-features = ["variable-refresh-rate" "scale-monitor-framebuffer"];
                center-new-windows = true;
              };

              "org/gnome/desktop/wm/keybindings" = {
                switch-applications = ["<Super>Tab"];
                switch-applications-backward = ["<Shift><Super>Tab"];
                switch-windows = ["<Alt>Tab"];
                switch-windows-backward = ["<Shift><Alt>Tab"];
              };

              "org/gnome/desktop/wm/preferences" = {
                button-layout = "appmenu:minimize,maximize,close";
              };

              "org/gnome/nautilus/preferences" = {
                default-folder-viewer = "list-view";
                show-create-link = true;
              };
              "org/gnome/nautilus/gtk" = {
                application-prefer-dark-theme = true;
              };

              "org/gtk/Settings/FileChooser" = {
                sort-directories-first = true;
              };
              "org/gtk/gtk4/Settings/FileChooser" = {
                sort-directories-first = true;
              };

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

              "org/gnome/shell/extensions/logo-menu" = {
                menu-button-terminal = "ghostty";
                menu-button-system-monitor = "missioncenter";
                menu-button-extensions-app = "com.mattjakeman.ExtensionManager.desktop";
                menu-button-software-center = "bazaar";
              };

              "app/devsuite/Ptyxis" = {
                prefer-dark-theme = true;
              };

              "app/zen-browser/zen" = {
                prefer-dark-theme = true;
              };
            };
          }
        ];

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

        environment.systemPackages = with pkgs;
          [
            (writeTextDir "share/applications/org.gnome.Extensions.desktop" ''
              [Desktop Entry]
              Type=Application
              Name=Extensions
              NoDisplay=true
            '')
            gnome-tweaks
          ]
          ++ lib.optionals cfg.gnome.extensions [
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

            yaru-theme
            colloid-icon-theme
            colloid-gtk-theme
            pantheon.elementary-sound-theme
            pantheon.elementary-gtk-theme
            pantheon.elementary-icon-theme
          ];
      })

      # ======== COSMIC VARIANT ========
      (lib.mkIf (cfg.variant == "cosmic") {
        services.desktopManager.cosmic.enable = true;
        services.displayManager.cosmic-greeter.enable = true;

        environment.sessionVariables = {
          NIXOS_OZONE_WL = "1";
          MOZ_ENABLE_WAYLAND = "1";
        };
      })

      # ======== NIRI VARIANT ========
      (lib.mkIf (cfg.variant == "niri") {
        programs.niri.enable = true;
        niri-flake.cache.enable = true;

        services.xserver.enable = true;

        services.displayManager.gdm = lib.mkIf cfg.niri.useGdm {
          enable = true;
          wayland = true;
        };

        services.greetd = lib.mkIf (!cfg.niri.useGdm) {
          enable = true;
          settings = {
            default_session = {
              command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --remember --remember-session --cmd niri-session";
              user = "greeter";
            };
          };
        };

        security.polkit.enable = true;
        security.rtkit.enable = true;
        security.pam.services.swaylock = {};
        services.gnome.gnome-keyring.enable = true;

        programs.dconf.enable = true;
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

        environment.sessionVariables = {
          NIXOS_OZONE_WL = "1";
          MOZ_ENABLE_WAYLAND = "1";
          QT_QPA_PLATFORM = "wayland;xcb";
          SDL_VIDEODRIVER = "wayland";
          _JAVA_AWT_WM_NONREPARENTING = "1";
        };

        services.pipewire = {
          enable = true;
          alsa.enable = true;
          alsa.support32Bit = true;
          pulse.enable = true;
          jack.enable = true;
        };

        hardware.bluetooth = {
          enable = true;
          powerOnBoot = true;
        };
        services.blueman.enable = true;

        networking.networkmanager.enable = true;

        services.gvfs.enable = true;
        services.udisks2.enable = true;
        services.tumbler.enable = true;

        hardware.steam-hardware.enable = lib.mkIf cfg.niri.gaming true;

        environment.systemPackages = with pkgs;
          [
            xwayland-satellite
            wl-clipboard
            cliphist

            waybar
            alacritty
            fuzzel

            mako
            libnotify

            swaylock
            swayidle
            swaybg
            waypaper

            grim
            slurp
            swappy
            wl-screenrec

            pavucontrol
            playerctl
            brightnessctl
            wlsunset

            mate.mate-polkit
            networkmanagerapplet
            blueman

            whitesur-gtk-theme
            whitesur-icon-theme
            whitesur-cursors
            adwaita-icon-theme
            gnome-themes-extra
            hicolor-icon-theme
          ]
          ++ lib.optionals cfg.niri.includeGnomeApps [
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
            loupe
            evince
            file-roller
            baobab
            gnome-text-editor
            seahorse
            gnome-settings-daemon
          ]
          ++ lib.optionals cfg.niri.gaming [
            wineWowPackages.stable
            gamescope
            goverlay
            vkbasalt
            protonplus
          ];
      })
    ]);
}
