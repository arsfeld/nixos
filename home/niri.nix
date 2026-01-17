# Niri home-manager configuration
# GNOME-like defaults for a comfortable transition from GNOME
{
  config,
  pkgs,
  lib,
  osConfig ? null,
  ...
}: let
  # Check if niri is enabled in the system configuration
  niriEnabled = osConfig != null && osConfig.constellation.niri.enable or false;
in {
  config = lib.mkIf niriEnabled {
    # Niri configuration file (KDL format)
    xdg.configFile."niri/config.kdl".text = ''
      // Niri configuration - GNOME-like defaults
      // See https://github.com/YaLTeR/niri/wiki/Configuration-Overview

      // Input configuration
      input {
          keyboard {
              xkb {
                  layout "us"
                  variant "alt-intl"
              }
              repeat-delay 300
              repeat-rate 50
          }

          touchpad {
              tap
              dwt  // disable-while-typing
              natural-scroll
              accel-speed 0.2
              accel-profile "adaptive"
          }

          mouse {
              accel-speed 0.0
              accel-profile "flat"
          }

          // Focus follows mouse
          focus-follows-mouse max-scroll-amount="0%"
      }

      // Output/display configuration
      output "eDP-1" {
          // Default laptop display
          scale 1.0
      }

      // Layout configuration
      layout {
          // Gaps between windows (like GNOME's Tiling Shell)
          gaps 8

          // Center focused column when there's extra space
          center-focused-column "never"

          // Default column width
          default-column-width { proportion 0.5; }

          // Preset column widths for cycling
          preset-column-widths {
              proportion 0.33333
              proportion 0.5
              proportion 0.66667
              proportion 1.0
          }

          // Focus ring (outline around focused window) - subtle macOS style
          focus-ring {
              width 2
              active-color "#3b82f6"
              inactive-color "#404040"
          }

          // Border around windows
          border {
              off
          }

          // Struts (reserved screen space)
          struts {
              // Leave space for waybar at top
              // top 32
          }
      }

      // Spawn processes at startup
      spawn-at-startup "eww" "open-many" "bar" "dock"
      spawn-at-startup "swaybg" "-m" "fill" "-i" "${pkgs.nixos-artwork.wallpapers.nineish-dark-gray}/share/backgrounds/nixos/nix-wallpaper-nineish-dark-gray.png"
      spawn-at-startup "mako"
      spawn-at-startup "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"
      spawn-at-startup "xwayland-satellite"
      spawn-at-startup "wl-paste" "--watch" "cliphist" "store"

      // Cursor configuration - WhiteSur macOS style
      cursor {
          xcursor-theme "WhiteSur-cursors"
          xcursor-size 24
      }

      // Allow client-side decorations (titlebars) for apps that need them
      // Use Mod+Q to close windows without titlebars

      // Screenshot path
      screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"

      // Animation configuration
      animations {
          // Enable smooth animations
          slowdown 1.0
      }

      // Window rules
      window-rule {
          // Make Firefox PIP windows floating
          match app-id="firefox" title="^Picture-in-Picture$"
          open-floating true
      }

      window-rule {
          // GNOME apps usually work better with CSD disabled
          match app-id="^org\\.gnome\\."
          // Default CSD handling
      }

      window-rule {
          // Spotify and other apps that need window controls
          match app-id="^Spotify$"
          match app-id="^spotify$"
          match app-id="^com\\.spotify\\.Client$"
          draw-border-with-background false
      }

      window-rule {
          // Flatpak apps - show border for close button visibility
          match app-id="^app\\."
          draw-border-with-background false
      }

      // Hotkey configuration - macOS-inspired
      binds {
          // Application launchers (macOS style)
          Mod+Space { spawn "fuzzel"; }  // Spotlight-style launcher
          Mod+D { spawn "fuzzel"; }  // Alternative launcher key
          Mod+Return { spawn "ghostty"; }
          Mod+T { spawn "ghostty"; }  // Terminal shortcut
          Mod+E { spawn "nautilus"; }  // File manager
          Mod+Period { spawn "gnome-characters"; }  // Emoji picker

          // Screenshot - like GNOME's PrintScreen
          Print { screenshot; }
          Ctrl+Print { screenshot-screen; }
          Alt+Print { screenshot-window; }

          // Window management
          Mod+Q { close-window; }
          Mod+F { maximize-column; }
          Mod+Shift+F { fullscreen-window; }
          Mod+C { center-column; }

          // Focus navigation (vim-style + arrows)
          Mod+H { focus-column-left; }
          Mod+J { focus-window-down; }
          Mod+K { focus-window-up; }
          Mod+L { focus-column-right; }
          Mod+Left { focus-column-left; }
          Mod+Down { focus-window-down; }
          Mod+Up { focus-window-up; }
          Mod+Right { focus-column-right; }

          // Move windows (vim-style + arrows)
          Mod+Shift+H { move-column-left; }
          Mod+Shift+J { move-window-down; }
          Mod+Shift+K { move-window-up; }
          Mod+Shift+L { move-column-right; }
          Mod+Shift+Left { move-column-left; }
          Mod+Shift+Down { move-window-down; }
          Mod+Shift+Up { move-window-up; }
          Mod+Shift+Right { move-column-right; }

          // Window sizing
          Mod+R { switch-preset-column-width; }
          Mod+Minus { set-column-width "-10%"; }
          Mod+Equal { set-column-width "+10%"; }
          Mod+Shift+Minus { set-window-height "-10%"; }
          Mod+Shift+Equal { set-window-height "+10%"; }

          // Workspace navigation (like GNOME)
          Mod+1 { focus-workspace 1; }
          Mod+2 { focus-workspace 2; }
          Mod+3 { focus-workspace 3; }
          Mod+4 { focus-workspace 4; }
          Mod+5 { focus-workspace 5; }
          Mod+6 { focus-workspace 6; }
          Mod+7 { focus-workspace 7; }
          Mod+8 { focus-workspace 8; }
          Mod+9 { focus-workspace 9; }

          // Move window to workspace
          Mod+Shift+1 { move-column-to-workspace 1; }
          Mod+Shift+2 { move-column-to-workspace 2; }
          Mod+Shift+3 { move-column-to-workspace 3; }
          Mod+Shift+4 { move-column-to-workspace 4; }
          Mod+Shift+5 { move-column-to-workspace 5; }
          Mod+Shift+6 { move-column-to-workspace 6; }
          Mod+Shift+7 { move-column-to-workspace 7; }
          Mod+Shift+8 { move-column-to-workspace 8; }
          Mod+Shift+9 { move-column-to-workspace 9; }

          // Workspace scrolling
          Mod+Page_Down { focus-workspace-down; }
          Mod+Page_Up { focus-workspace-up; }
          Mod+Shift+Page_Down { move-column-to-workspace-down; }
          Mod+Shift+Page_Up { move-column-to-workspace-up; }

          // Monitor focus
          Mod+Ctrl+H { focus-monitor-left; }
          Mod+Ctrl+L { focus-monitor-right; }
          Mod+Ctrl+Left { focus-monitor-left; }
          Mod+Ctrl+Right { focus-monitor-right; }

          // Move window to monitor
          Mod+Ctrl+Shift+H { move-column-to-monitor-left; }
          Mod+Ctrl+Shift+L { move-column-to-monitor-right; }
          Mod+Ctrl+Shift+Left { move-column-to-monitor-left; }
          Mod+Ctrl+Shift+Right { move-column-to-monitor-right; }

          // Scrolling through columns (niri's unique feature)
          Mod+Home { focus-column-first; }
          Mod+End { focus-column-last; }

          // Consume window into column / expel from column
          Mod+Comma { consume-window-into-column; }
          Mod+Shift+Comma { expel-window-from-column; }

          // Toggle floating
          Mod+V { toggle-window-floating; }
          Mod+Shift+V { switch-focus-between-floating-and-tiling; }

          // System controls
          Mod+Shift+E { quit; }
          Mod+Shift+P { power-off-monitors; }

          // Lock screen (like GNOME Super+L)
          Mod+Escape { spawn "swaylock"; }

          // Audio controls (using pactl for GNOME-like experience)
          XF86AudioRaiseVolume allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%+"; }
          XF86AudioLowerVolume allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"; }
          XF86AudioMute allow-when-locked=true { spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"; }
          XF86AudioMicMute allow-when-locked=true { spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SOURCE@" "toggle"; }

          // Media controls
          XF86AudioPlay allow-when-locked=true { spawn "playerctl" "play-pause"; }
          XF86AudioNext allow-when-locked=true { spawn "playerctl" "next"; }
          XF86AudioPrev allow-when-locked=true { spawn "playerctl" "previous"; }

          // Brightness controls
          XF86MonBrightnessUp allow-when-locked=true { spawn "brightnessctl" "set" "5%+"; }
          XF86MonBrightnessDown allow-when-locked=true { spawn "brightnessctl" "set" "5%-"; }
      }
    '';

    # EWW configuration - declarative bar and dock
    xdg.configFile."eww/eww.yuck".text = ''
      ; Variables
      (defpoll time :interval "1s" "date '+%a %b %d  %H:%M'")
      (defpoll battery :interval "10s" "cat /sys/class/power_supply/BAT*/capacity 2>/dev/null || echo 100")
      (defpoll battery_status :interval "10s" "cat /sys/class/power_supply/BAT*/status 2>/dev/null || echo 'Full'")
      (defpoll volume :interval "1s" "wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2*100)}'")
      (defpoll wifi :interval "10s" "nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2 || echo 'Disconnected'")

      ; Top Bar
      (defwidget bar []
        (centerbox :class "bar"
          (workspaces)
          (clock)
          (sidestuff)))

      (defwidget workspaces []
        (box :class "workspaces" :orientation "h" :space-evenly false :halign "start"
          (for ws in "[1, 2, 3, 4, 5]"
            (button :class "workspace-btn" :onclick "niri msg action focus-workspace ''${ws}" "''${ws}"))))

      (defwidget clock []
        (box :class "clock" :halign "center"
          (label :text time)))

      (defwidget sidestuff []
        (box :class "sidestuff" :orientation "h" :space-evenly false :halign "end" :spacing 16
          (volume-widget)
          (wifi-widget)
          (battery-widget)))

      (defwidget volume-widget []
        (button :class "volume" :onclick "pavucontrol &"
          (label :text {volume == "" ? "󰖁" : volume < 30 ? "󰕿" : volume < 70 ? "󰖀" : "󰕾"})))

      (defwidget wifi-widget []
        (box :class "wifi" :tooltip wifi
          (label :text {wifi == "Disconnected" ? "󰖪" : "󰖩"})))

      (defwidget battery-widget []
        (box :class "battery" :tooltip "''${battery}%"
          (label :text {battery_status == "Charging" ? "󰂄" :
                        battery < 10 ? "󰂎" :
                        battery < 20 ? "󰁺" :
                        battery < 30 ? "󰁻" :
                        battery < 40 ? "󰁼" :
                        battery < 50 ? "󰁽" :
                        battery < 60 ? "󰁾" :
                        battery < 70 ? "󰁿" :
                        battery < 80 ? "󰂀" :
                        battery < 90 ? "󰂁" : "󰁹"})
          (label :text " ''${battery}%")))

      ; Dock
      (defwidget dock []
        (box :class "dock" :orientation "h" :space-evenly false :halign "center" :spacing 4
          (dock-item :icon "com.mitchellh.ghostty" :cmd "ghostty")
          (dock-item :icon "app.zen_browser.zen" :cmd "flatpak run app.zen_browser.zen")
          (dock-item :icon "steam" :cmd "steam")))

      (defwidget dock-item [icon cmd]
        (eventbox :class "dock-item-box"
          :onhover "''${EWW_CMD} update hovered_icon=''${icon}"
          :onhoverlost "''${EWW_CMD} update hovered_icon="
          (button :class "dock-item ''${hovered_icon == icon ? "hovered" : ""}" :onclick "''${cmd} &"
            (image :path "" :image-width {hovered_icon == icon ? 64 : 48} :image-height {hovered_icon == icon ? 64 : 48} :icon icon :icon-size "dialog"))))

      (defvar hovered_icon "")

      ; Windows
      (defwindow bar
        :monitor 0
        :geometry (geometry :x "0%" :y "4px" :width "98%" :height "32px" :anchor "top center")
        :stacking "fg"
        :exclusive true
        :namespace "eww-bar"
        (bar))

      (defwindow dock
        :monitor 0
        :geometry (geometry :x "0%" :y "8px" :width "250px" :height "72px" :anchor "bottom center")
        :stacking "overlay"
        :exclusive false
        :focusable false
        :namespace "eww-dock"
        (dock))
    '';

    xdg.configFile."eww/eww.scss".text = ''
      // Variables
      $bg: rgba(30, 30, 30, 0.85);
      $bg-light: rgba(255, 255, 255, 0.1);
      $fg: #ffffff;
      $fg-dim: rgba(255, 255, 255, 0.6);
      $accent: #3b82f6;
      $border: rgba(255, 255, 255, 0.1);
      $radius: 14px;

      // Reset
      * {
        all: unset;
        font-family: "Inter", "SF Pro Display", sans-serif;
        font-size: 13px;
      }

      // Top Bar
      .bar {
        background: $bg;
        border-radius: $radius;
        border: 1px solid $border;
        padding: 0 12px;
      }

      .workspaces {
        .workspace-btn {
          padding: 4px 10px;
          margin: 4px 2px;
          border-radius: 6px;
          color: $fg-dim;
          transition: all 200ms ease;

          &:hover {
            background: $bg-light;
            color: $fg;
          }
        }
      }

      .clock {
        color: $fg;
        font-weight: 600;
      }

      .sidestuff {
        padding-right: 8px;

        .volume, .wifi, .battery {
          color: $fg-dim;
          padding: 4px 8px;

          &:hover {
            color: $fg;
          }
        }
      }

      // Dock - macOS style
      .dock {
        background: $bg;
        border-radius: 18px;
        border: 1px solid $border;
        padding: 6px 12px;

        .dock-item-box {
          margin: 0 2px;
        }

        .dock-item {
          padding: 4px;
          border-radius: 12px;
          transition: all 150ms cubic-bezier(0.4, 0, 0.2, 1);
          margin-bottom: 0;

          &.hovered {
            margin-bottom: 8px;
          }
        }
      }

      // Tooltips
      tooltip {
        background: $bg;
        border: 1px solid $border;
        border-radius: 8px;
        padding: 4px 8px;
        color: $fg;
      }
    '';

    # Mako notification daemon configuration - macOS style
    xdg.configFile."mako/config".text = ''
      # Mako configuration - macOS-style notifications
      sort=-time
      layer=overlay
      anchor=top-right
      font=Inter 12
      background-color=#1e1e1eee
      text-color=#ffffff
      width=380
      height=120
      margin=12
      padding=16
      border-size=1
      border-color=#ffffff20
      border-radius=14
      default-timeout=5000
      ignore-timeout=1
      max-visible=4
      icon-path=/run/current-system/sw/share/icons/WhiteSur-dark
      icons=1
      max-icon-size=48

      [urgency=low]
      border-color=#ffffff10
      default-timeout=3000

      [urgency=high]
      border-color=#ff5252
      default-timeout=0
    '';

    # Swaylock configuration - macOS style
    xdg.configFile."swaylock/config".text = ''
      # Swaylock configuration - macOS inspired
      ignore-empty-password
      show-failed-attempts
      daemonize

      # Colors (Dark, minimal like macOS)
      color=1a1a1a
      inside-color=1a1a1a
      inside-clear-color=3b82f6
      inside-ver-color=3b82f6
      inside-wrong-color=ef4444
      key-hl-color=ffffff
      line-color=1a1a1a
      ring-color=333333
      ring-clear-color=3b82f6
      ring-ver-color=3b82f6
      ring-wrong-color=ef4444
      text-color=ffffff
      text-clear-color=ffffff
      text-ver-color=ffffff
      text-wrong-color=ffffff
      separator-color=1a1a1a

      # Font
      font=Inter
      font-size=24

      # Indicator - larger, more prominent
      indicator-radius=120
      indicator-thickness=8
    '';

    # Swayidle configuration for automatic locking
    xdg.configFile."swayidle/config".text = ''
      timeout 300 'swaylock -f'
      timeout 600 'niri msg action power-off-monitors'
      before-sleep 'swaylock -f'
    '';

    # Fuzzel application launcher configuration - macOS style (backup launcher)
    xdg.configFile."fuzzel/fuzzel.ini".text = ''
      # Fuzzel configuration - macOS Spotlight style
      [main]
      font=Inter:size=14
      dpi-aware=auto
      prompt="  "
      icon-theme=WhiteSur-dark
      terminal=ghostty
      layer=overlay
      width=45
      lines=8

      [colors]
      background=1e1e1ed9
      text=ffffffff
      match=3b82f6ff
      selection=ffffff15
      selection-text=ffffffff
      selection-match=3b82f6ff
      border=ffffff18

      [border]
      width=1
      radius=14
    '';

    # Create Pictures/Screenshots directory
    home.file."Pictures/Screenshots/.keep".text = "";

    # GTK settings - WhiteSur macOS theme
    gtk = {
      enable = true;
      theme = {
        name = "WhiteSur-Dark";
        package = pkgs.whitesur-gtk-theme;
      };
      iconTheme = {
        name = "WhiteSur-dark";
        package = pkgs.whitesur-icon-theme;
      };
      cursorTheme = {
        name = "WhiteSur-cursors";
        package = pkgs.whitesur-cursors;
        size = 24;
      };
      gtk3.extraConfig = {
        gtk-application-prefer-dark-theme = true;
      };
      gtk4.extraConfig = {
        gtk-application-prefer-dark-theme = true;
      };
    };

    # Qt settings to follow GTK theme
    qt = {
      enable = true;
      platformTheme.name = "gtk";
      style.name = "adwaita-dark";
    };

    # Anyrun launcher configuration - macOS Spotlight style
    xdg.configFile."anyrun/config.ron".text = ''
      Config(
        x: Fraction(0.5),
        y: Fraction(0.3),
        width: Absolute(600),
        height: Absolute(0),
        hide_icons: false,
        ignore_exclusive_zones: false,
        layer: Overlay,
        hide_plugin_info: true,
        close_on_click: true,
        show_results_immediately: true,
        max_entries: Some(8),
        plugins: [
          "${pkgs.anyrun}/lib/libapplications.so",
          "${pkgs.anyrun}/lib/libshell.so",
          "${pkgs.anyrun}/lib/librink.so",
        ],
      )
    '';

    xdg.configFile."anyrun/style.css".text = ''
      /* macOS Spotlight-inspired theme */
      * {
        all: unset;
        font-family: "Inter", "SF Pro Display", sans-serif;
        font-size: 14px;
      }

      #window {
        background: transparent;
      }

      box#main {
        background: rgba(30, 30, 30, 0.85);
        border: 1px solid rgba(255, 255, 255, 0.1);
        border-radius: 16px;
        padding: 8px;
        box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5);
      }

      entry#entry {
        background: rgba(255, 255, 255, 0.08);
        border: none;
        border-radius: 10px;
        padding: 12px 16px;
        margin-bottom: 8px;
        color: #ffffff;
        caret-color: #ffffff;
        font-size: 18px;
      }

      entry#entry:focus {
        background: rgba(255, 255, 255, 0.1);
      }

      entry#entry placeholder {
        color: rgba(255, 255, 255, 0.4);
      }

      list#main {
        background: transparent;
      }

      row#entry {
        padding: 8px 12px;
        border-radius: 8px;
        margin: 2px 0;
      }

      row#entry:selected {
        background: rgba(255, 255, 255, 0.1);
      }

      row#entry:hover {
        background: rgba(255, 255, 255, 0.05);
      }

      box#match {
        padding: 4px;
      }

      label#match-title {
        color: #ffffff;
        font-weight: 500;
        font-size: 14px;
      }

      label#match-desc {
        color: rgba(255, 255, 255, 0.5);
        font-size: 12px;
      }

      image#match-icon {
        margin-right: 12px;
      }
    '';
  };
}
