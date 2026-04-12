# Niri home-manager configuration
# Declarative niri config via niri-flake with waybar, mako, swaylock, fuzzel
{
  config,
  pkgs,
  lib,
  osConfig ? null,
  ...
}: let
  # Check if niri is enabled in the system configuration
  niriEnabled = osConfig != null && osConfig.constellation.niri.enable or false;
  # programs.niri.settings is only available when niri-flake's HM module is loaded
  # (auto-imported by niri-flake's NixOS module on Linux). Guard against macOS/standalone HM.
  hasNiriModule = config.programs ? niri;
in {
  config = lib.mkIf (niriEnabled && hasNiriModule) {
    # Declarative niri configuration via niri-flake (build-time validated)
    programs.niri.settings = {
      # Input configuration
      input = {
        keyboard = {
          xkb = {
            layout = "us";
            variant = "alt-intl";
          };
          repeat-delay = 300;
          repeat-rate = 50;
        };

        touchpad = {
          tap = true;
          dwt = true; # disable-while-typing
          natural-scroll = true;
          accel-speed = 0.2;
          accel-profile = "adaptive";
        };

        mouse = {
          accel-speed = 0.0;
          accel-profile = "flat";
        };

        focus-follows-mouse = {
          enable = true;
          max-scroll-amount = "0%";
        };
      };

      # Output/display configuration
      outputs."eDP-1" = {
        scale = 1.0;
      };

      # Layout configuration
      layout = {
        gaps = 8;
        center-focused-column = "never";

        default-column-width = {proportion = 0.5;};

        preset-column-widths = [
          {proportion = 0.33333;}
          {proportion = 0.5;}
          {proportion = 0.66667;}
          {proportion = 1.0;}
        ];

        # Focus ring - subtle macOS style
        focus-ring = {
          width = 2;
          active.color = "#3b82f6";
          inactive.color = "#404040";
        };

        border.enable = false;
      };

      # Spawn processes at startup
      spawn-at-startup = [
        {argv = ["waybar"];}
        {argv = ["swaybg" "-m" "fill" "-i" "${pkgs.nixos-artwork.wallpapers.nineish-dark-gray}/share/backgrounds/nixos/nix-wallpaper-nineish-dark-gray.png"];}
        {argv = ["mako"];}
        {argv = ["${pkgs.mate.mate-polkit}/libexec/polkit-mate-authentication-agent-1"];}
        {argv = ["wl-paste" "--watch" "cliphist" "store"];}
      ];

      # Cursor configuration - WhiteSur macOS style
      cursor = {
        theme = "WhiteSur-cursors";
        size = 24;
      };

      # Screenshot path
      screenshot-path = "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png";

      # Prefer server-side decorations
      prefer-no-csd = true;

      # Skip hotkey overlay at startup
      hotkey-overlay.skip-at-startup = true;

      # Animation configuration
      animations.slowdown = 1.0;

      # XWayland satellite integration (auto-managed since v25.08)
      xwayland-satellite.enable = true;

      # Window rules
      window-rules = [
        {
          # Firefox PIP floating
          matches = [
            {
              app-id = "firefox";
              title = "^Picture-in-Picture$";
            }
          ];
          open-floating = true;
        }
        {
          # Spotify - no border background (transparent CSD)
          matches = [
            {app-id = "^Spotify$";}
            {app-id = "^spotify$";}
            {app-id = "^com\\.spotify\\.Client$";}
          ];
          draw-border-with-background = false;
        }
        {
          # Flatpak apps - show border for close button visibility
          matches = [{app-id = "^app\\.";}];
          draw-border-with-background = false;
        }
      ];

      # Keybindings
      binds = let
        spawn = cmd: {action.spawn = cmd;};
        spawnArgs = args: {action.spawn = args;};
        act = name: {action.${name} = [];};
        actVal = name: val: {action.${name} = val;};
        locked = action: action // {allow-when-locked = true;};
      in {
        # Application launchers
        "Mod+Space" = spawn "fuzzel";
        "Mod+D" = spawn "fuzzel";
        "Mod+Return" = spawn "ghostty";
        "Mod+T" = spawn "ghostty";
        "Mod+E" = spawn "nautilus";
        "Mod+Period" = spawn "gnome-characters";

        # Screenshots (niri built-in)
        "Print" = act "screenshot";
        "Ctrl+Print" = act "screenshot-screen";
        "Alt+Print" = act "screenshot-window";

        # Window management
        "Mod+Q" = act "close-window";
        "Mod+F" = act "maximize-column";
        "Mod+Shift+F" = act "fullscreen-window";
        "Mod+C" = act "center-column";

        # Focus navigation (vim-style + arrows)
        "Mod+H" = act "focus-column-left";
        "Mod+J" = act "focus-window-down";
        "Mod+K" = act "focus-window-up";
        "Mod+L" = act "focus-column-right";
        "Mod+Left" = act "focus-column-left";
        "Mod+Down" = act "focus-window-down";
        "Mod+Up" = act "focus-window-up";
        "Mod+Right" = act "focus-column-right";

        # Move windows (vim-style + arrows)
        "Mod+Shift+H" = act "move-column-left";
        "Mod+Shift+J" = act "move-window-down";
        "Mod+Shift+K" = act "move-window-up";
        "Mod+Shift+L" = act "move-column-right";
        "Mod+Shift+Left" = act "move-column-left";
        "Mod+Shift+Down" = act "move-window-down";
        "Mod+Shift+Up" = act "move-window-up";
        "Mod+Shift+Right" = act "move-column-right";

        # Window sizing
        "Mod+R" = act "switch-preset-column-width";
        "Mod+Minus" = actVal "set-column-width" "-10%";
        "Mod+Equal" = actVal "set-column-width" "+10%";
        "Mod+Shift+Minus" = actVal "set-window-height" "-10%";
        "Mod+Shift+Equal" = actVal "set-window-height" "+10%";

        # Workspace navigation
        "Mod+1" = actVal "focus-workspace" 1;
        "Mod+2" = actVal "focus-workspace" 2;
        "Mod+3" = actVal "focus-workspace" 3;
        "Mod+4" = actVal "focus-workspace" 4;
        "Mod+5" = actVal "focus-workspace" 5;
        "Mod+6" = actVal "focus-workspace" 6;
        "Mod+7" = actVal "focus-workspace" 7;
        "Mod+8" = actVal "focus-workspace" 8;
        "Mod+9" = actVal "focus-workspace" 9;

        # Move window to workspace
        "Mod+Shift+1" = actVal "move-column-to-workspace" 1;
        "Mod+Shift+2" = actVal "move-column-to-workspace" 2;
        "Mod+Shift+3" = actVal "move-column-to-workspace" 3;
        "Mod+Shift+4" = actVal "move-column-to-workspace" 4;
        "Mod+Shift+5" = actVal "move-column-to-workspace" 5;
        "Mod+Shift+6" = actVal "move-column-to-workspace" 6;
        "Mod+Shift+7" = actVal "move-column-to-workspace" 7;
        "Mod+Shift+8" = actVal "move-column-to-workspace" 8;
        "Mod+Shift+9" = actVal "move-column-to-workspace" 9;

        # Workspace scrolling
        "Mod+Page_Down" = act "focus-workspace-down";
        "Mod+Page_Up" = act "focus-workspace-up";
        "Mod+Shift+Page_Down" = act "move-column-to-workspace-down";
        "Mod+Shift+Page_Up" = act "move-column-to-workspace-up";

        # Monitor focus
        "Mod+Ctrl+H" = act "focus-monitor-left";
        "Mod+Ctrl+L" = act "focus-monitor-right";
        "Mod+Ctrl+Left" = act "focus-monitor-left";
        "Mod+Ctrl+Right" = act "focus-monitor-right";

        # Move window to monitor
        "Mod+Ctrl+Shift+H" = act "move-column-to-monitor-left";
        "Mod+Ctrl+Shift+L" = act "move-column-to-monitor-right";
        "Mod+Ctrl+Shift+Left" = act "move-column-to-monitor-left";
        "Mod+Ctrl+Shift+Right" = act "move-column-to-monitor-right";

        # Scrolling through columns
        "Mod+Home" = act "focus-column-first";
        "Mod+End" = act "focus-column-last";

        # Consume window into column / expel from column
        "Mod+Comma" = act "consume-window-into-column";
        "Mod+Shift+Comma" = act "expel-window-from-column";

        # Toggle floating
        "Mod+V" = act "toggle-window-floating";
        "Mod+Shift+V" = act "switch-focus-between-floating-and-tiling";

        # Overview (niri v25.05+)
        "Mod+Tab" = act "toggle-overview";

        # System controls
        "Mod+Shift+E" = {action.quit = {skip-confirmation = true;};};
        "Mod+Shift+P" = act "power-off-monitors";

        # Lock screen
        "Mod+Escape" = spawn "swaylock";

        # Audio controls (wpctl - PipeWire native)
        "XF86AudioRaiseVolume" = locked (spawnArgs ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%+"]);
        "XF86AudioLowerVolume" = locked (spawnArgs ["wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"]);
        "XF86AudioMute" = locked (spawnArgs ["wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"]);
        "XF86AudioMicMute" = locked (spawnArgs ["wpctl" "set-mute" "@DEFAULT_AUDIO_SOURCE@" "toggle"]);

        # Media controls
        "XF86AudioPlay" = locked (spawn "playerctl play-pause");
        "XF86AudioNext" = locked (spawn "playerctl next");
        "XF86AudioPrev" = locked (spawn "playerctl previous");

        # Brightness controls
        "XF86MonBrightnessUp" = locked (spawnArgs ["brightnessctl" "set" "5%+"]);
        "XF86MonBrightnessDown" = locked (spawnArgs ["brightnessctl" "set" "5%-"]);
      };
    };

    # Waybar - status bar with native niri support
    programs.waybar = {
      enable = true;
      # Don't use systemd — niri spawns waybar via spawn-at-startup
      systemd.enable = false;
      settings = [
        {
          layer = "top";
          position = "top";
          height = 32;
          spacing = 4;
          margin-top = 4;
          margin-left = 8;
          margin-right = 8;

          modules-left = ["niri/workspaces"];
          modules-center = ["niri/window"];
          modules-right = ["niri/language" "wireplumber" "network" "battery" "tray" "clock"];

          "niri/workspaces" = {
            format = "{icon}";
            format-icons = {
              focused = "";
              active = "";
              default = "";
            };
          };

          "niri/window" = {
            format = "{title}";
            icon = true;
            icon-size = 18;
            max-length = 60;
            separate-outputs = true;
          };

          "niri/language" = {
            format = "{short}";
          };

          clock = {
            format = "{:%a %b %d  %H:%M}";
            format-alt = "{:%A, %B %d, %Y}";
            tooltip-format = "<tt>{calendar}</tt>";
          };

          wireplumber = {
            format = "{icon} {volume}%";
            format-muted = "󰝟";
            format-icons = ["" "" ""];
            on-click = "pavucontrol";
          };

          network = {
            format-wifi = "󰖩";
            format-ethernet = "󰈀";
            format-disconnected = "󰖪";
            tooltip-format-wifi = "{essid} ({signalStrength}%)";
            tooltip-format-ethernet = "{ifname}";
          };

          battery = {
            format = "{icon} {capacity}%";
            format-charging = "󰂄 {capacity}%";
            format-icons = ["󰂎" "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰁹"];
            states = {
              warning = 20;
              critical = 10;
            };
          };

          tray = {
            spacing = 8;
          };
        }
      ];

      style = ''
        * {
          font-family: "Inter", "JetBrains Mono Nerd Font", sans-serif;
          font-size: 13px;
        }

        window#waybar {
          background: rgba(30, 30, 30, 0.85);
          border-radius: 14px;
          border: 1px solid rgba(255, 255, 255, 0.1);
          color: #ffffff;
        }

        #workspaces button {
          padding: 0 8px;
          color: rgba(255, 255, 255, 0.6);
          border-radius: 6px;
          margin: 4px 2px;
        }

        #workspaces button.focused {
          background: rgba(255, 255, 255, 0.1);
          color: #ffffff;
        }

        #workspaces button.active {
          color: rgba(255, 255, 255, 0.9);
        }

        #window {
          font-weight: 600;
        }

        #clock, #battery, #network, #wireplumber, #language, #tray {
          padding: 0 10px;
          color: rgba(255, 255, 255, 0.8);
        }

        #battery.warning {
          color: #f59e0b;
        }

        #battery.critical {
          color: #ef4444;
        }

        tooltip {
          background: rgba(30, 30, 30, 0.95);
          border: 1px solid rgba(255, 255, 255, 0.1);
          border-radius: 8px;
          color: #ffffff;
        }
      '';
    };

    # Mako notification daemon configuration - macOS style
    xdg.configFile."mako/config".text = ''
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
      ignore-empty-password
      show-failed-attempts
      daemonize

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

      font=Inter
      font-size=24

      indicator-radius=120
      indicator-thickness=8
    '';

    # Swayidle configuration for automatic locking
    xdg.configFile."swayidle/config".text = ''
      timeout 300 'swaylock -f'
      timeout 600 'niri msg action power-off-monitors'
      before-sleep 'swaylock -f'
    '';

    # Fuzzel application launcher configuration - macOS Spotlight style
    xdg.configFile."fuzzel/fuzzel.ini".text = ''
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
  };
}
