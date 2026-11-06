# Vicinae: a Raycast/Spotlight-style launcher, a centred search bar on Super+Space.
#
# Gala has no wlr-layer-shell, so Vicinae draws as an ordinary undecorated
# window, which Gala centres; layer_shell is turned off so it does not try.
# For the same reason it cannot register a global shortcut itself: the key is
# a gnome-settings-daemon custom keybinding running `vicinae toggle`, which
# talks to the server the user unit keeps running.
#
# Super+Space is GNOME's input-source switch. raider has a single layout
# (us+alt-intl), so the launcher takes the key.
#
# The keybindings go through home-manager, not the system dconf database: the
# Pantheon user database already holds `custom-keybindings = @as []`, which
# shadows any system default. home-manager's dconf writes land in that
# database (see the Pantheon variant in modules/desktop/desktop.nix), so they
# are gated on it.
#
# No clipboard history: Gala offers no data-control protocol, so Vicinae runs
# its "dummy" clipboard server and the default clipboard favourite is dropped.
{
  configurations.nixos.raider.module = {
    config,
    lib,
    ...
  }: let
    vicinae = config.home-manager.users.arosenfeld.programs.vicinae.package;
    path = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vicinae/";
  in {
    home-manager.users.arosenfeld = {
      programs.vicinae = {
        enable = true;
        systemd.enable = true;
        # Changes made in Vicinae's own preferences survive; these keys win.
        mutableSettings = true;
        settings = {
          launcher_window.layer_shell.enabled = false;
          # Pantheon's style is light by default; the launcher stays dark.
          theme.light.name = "vicinae-dark";
          theme.dark.name = "vicinae-dark";
          close_on_focus_loss = true;
          pop_to_root_on_close = true;
          favorites = [];
          tray.enabled = false;
        };
      };

      dconf.settings = lib.mkIf (config.constellation.desktop.variant == "pantheon") {
        "org/gnome/desktop/wm/keybindings" = {
          switch-input-source = ["XF86Keyboard"];
          switch-input-source-backward = ["<Shift>XF86Keyboard"];
        };
        "org/gnome/settings-daemon/plugins/media-keys".custom-keybindings = [path];
        "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vicinae" = {
          name = "Vicinae";
          command = "${lib.getExe' vicinae "vicinae"} toggle";
          binding = "<Super>space";
        };
      };
    };
  };
}
