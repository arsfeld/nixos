# GTK look: Ubuntu's Yaru theme for GTK apps, icons and cursor.
#
# The theme is written to the *user* dconf database via home-manager, not just
# to the system database that constellation.desktop.gnome.theme feeds. Keys in
# the user database shadow system defaults, and a user database that has ever
# been touched by GNOME Settings or Tweaks already holds its own values, so
# system defaults alone silently lose. GTK and libadwaita apps read these keys
# under COSMIC too; COSMIC's own theme is set in COSMIC Settings.
#
# Deliberately no home-manager `gtk` module: it links ~/.config/gtk-{3,4}.0/
# settings.ini, which GTK tools rewrite as plain files, and the resulting
# backup collision aborts the whole home-manager activation. GTK on Wayland
# reads these settings from dconf anyway.
{
  config,
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
  };
}
