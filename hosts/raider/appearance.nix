# GNOME look: Ubuntu's Yaru theme for GTK, the shell, icons and cursor.
#
# The theme is written to the *user* dconf database via home-manager, not just
# to the system database that constellation.desktop.gnome.theme feeds. Keys in
# the user database shadow system defaults, and a user database that has ever
# been touched by GNOME Settings or Tweaks already holds its own values, so
# system defaults alone silently lose.
#
# Deliberately no home-manager `gtk` module: it links ~/.config/gtk-{3,4}.0/
# settings.ini, which GNOME tools rewrite as plain files, and the resulting
# backup collision aborts the whole home-manager activation. GNOME on Wayland
# reads these settings from dconf anyway.
{
  config,
  lib,
  pkgs,
  ...
}: let
  theme = config.constellation.desktop.gnome.theme;
in {
  constellation.desktop.gnome.theme = {
    gtk = "Yaru-dark";
    icon = "Yaru-dark";
  };

  environment.systemPackages = [pkgs.yaru-theme];

  home-manager.users.arosenfeld.dconf.settings = {
    "org/gnome/desktop/interface" = {
      gtk-theme = theme.gtk;
      icon-theme = theme.icon;
      cursor-theme = "Yaru";
      cursor-size = 24;
      color-scheme = "prefer-dark";
      # libadwaita apps ignore gtk-theme; orange keeps them in line with Yaru.
      accent-color = "orange";
    };

    "org/gnome/desktop/wm/preferences" = {
      button-layout = "appmenu:minimize,maximize,close";
    };

    "org/gnome/shell/extensions/user-theme" = {
      name = theme.gtk;
    };
  };

  # Shell extension layout. These keys are not touched by the user, so system
  # defaults are enough.
  programs.dconf.profiles.user.databases = [
    {
      settings = {
        "org/gnome/shell/extensions/Logo-menu" = {
          symbolic-icon = true;
          menu-button-icon-image = lib.gvariant.mkInt32 0; # icon theme start-here-symbolic
          menu-button-icon-size = lib.gvariant.mkInt32 20;
          hide-icon-shadow = false;
          menu-button-terminal = "ghostty";
          menu-button-system-monitor = "missioncenter";
          menu-button-extensions-app = "com.mattjakeman.ExtensionManager.desktop";
          menu-button-software-center = "bazaar";
          show-activities-button = true;
          hide-forcequit = true;
          show-lockscreen = false;
          show-power-options = false;
        };

        "org/gnome/shell/extensions/dash-to-dock" = {
          dock-position = "BOTTOM";
          dock-fixed = false;
          autohide = true;
          intellihide = true;
          extend-height = false;
          custom-theme-shrink = true;
          dash-max-icon-size = lib.gvariant.mkInt32 48;
          running-indicator-style = "DOTS";
          show-trash = true;
          show-mounts = false;
          transparency-mode = "DYNAMIC";
          apply-custom-theme = false;
        };

        "org/gnome/shell/extensions/blur-my-shell/dash-to-dock" = {
          blur = true;
          pipeline = "pipeline_default";
        };

        "org/gnome/shell/extensions/blur-my-shell/panel" = {
          blur = true;
          pipeline = "pipeline_default";
        };
      };
    }
  ];
}
