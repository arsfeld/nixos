# Vicinae: a Raycast/Spotlight-style launcher, a centred search bar on Super+Space.
#
# Gala has no wlr-layer-shell, so Vicinae draws as an ordinary undecorated
# window, which Gala centres; layer_shell is turned off so it does not try.
# For the same reason it cannot register a global shortcut itself: the key is
# an elementary application shortcut running `vicinae toggle`, which talks to
# the server the user unit keeps running.
#
# The shortcut is written to io.elementary.settings-daemon's own list, not to
# gnome-settings-daemon's custom-keybindings: at every login elementary's
# daemon moves anything found there into its list and empties the GNOME one.
# Writing elementary's list directly means this module owns it, so shortcuts
# added in System Settings are replaced at the next activation; add them here.
#
# Super+Space is Gala's input-source switch. raider has a single layout
# (us+alt-intl), so the launcher takes the key.
#
# These go through home-manager, not the system dconf database, because the
# user database already holds values for them, which shadow system defaults.
# home-manager's dconf writes land in the Pantheon database (see the Pantheon
# variant in modules/desktop/desktop.nix), so they are gated on it.
#
# No clipboard history: Gala offers no data-control protocol, so Vicinae runs
# its "dummy" clipboard server and the default clipboard favourite is dropped.
{
  configurations.nixos.raider.module = {
    config,
    lib,
    ...
  }: let
    pantheon = config.constellation.desktop.variant == "pantheon";
  in {
    home-manager.users.arosenfeld = {
      config,
      lib,
      ...
    }: let
      vicinae = config.programs.vicinae.package;
      gvariant = lib.hm.gvariant;
    in {
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

      dconf.settings = lib.mkIf pantheon {
        # Gala grabs the input-source switch from its own schema, not from
        # org.gnome.desktop.wm.keybindings; while it holds Super+Space the
        # launcher's grab fails ("Failed to grab accelerator").
        "io/elementary/desktop/wm/keybindings" = {
          switch-input-source = gvariant.mkEmptyArray gvariant.type.string;
          switch-input-source-backward = gvariant.mkEmptyArray gvariant.type.string;
        };
        # Type 1 runs a command line; the a{sv} is unused parameters.
        "io/elementary/settings-daemon/applications".application-shortcuts = [
          (gvariant.mkTuple [
            (gvariant.mkInt32 1)
            "${lib.getExe' vicinae "vicinae"} toggle"
            (gvariant.mkEmptyArray (gvariant.type.dictionaryEntryOf [gvariant.type.string gvariant.type.variant]))
            ["<Super>space"]
          ])
        ];
      };
    };
  };
}
