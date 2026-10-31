/*
 * macOS-style Game Mode indicator: a controller icon in Wingpanel exactly while
 * gamemoded has a registered game, and a popover naming the game(s). Read-only.
 *
 * Every change of state logs one line ("GameMode on: <n> game(s)",
 * "GameMode off") and every popover refresh logs the names it shows; the VM test
 * (tests/pantheon-gamemode-test.nix) asserts on them, so keep them stable.
 */
public class GameModeIndicator.Indicator : Wingpanel.Indicator {
    private Client client;
    private Gtk.Image? icon = null;
    private Gtk.Box? popover = null;
    private Gtk.Box? games_box = null;

    public Indicator () {
        Object (code_name: "gamemode");
    }

    construct {
        client = new Client ();
        client.notify["count"].connect (() => {
            visible = client.count > 0;
            if (visible) {
                message ("GameMode on: %d game(s)", client.count);
            } else {
                message ("GameMode off");
            }
        });
    }

    public override Gtk.Widget get_display_widget () {
        if (icon == null) {
            icon = new Gtk.Image.from_icon_name ("input-gaming-symbolic", Gtk.IconSize.LARGE_TOOLBAR) {
                tooltip_text = "Game Mode is on"
            };
        }
        return icon;
    }

    public override Gtk.Widget? get_widget () {
        if (popover == null) {
            var title = new Gtk.Label ("Game Mode") {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12
            };
            title.get_style_context ().add_class ("h4");

            var state = new Gtk.Label ("On") {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12
            };
            state.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);

            var separator = new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
                margin_top = 6,
                margin_bottom = 3
            };

            games_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                margin_bottom = 3
            };

            popover = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                width_request = 200
            };
            popover.add (title);
            popover.add (state);
            popover.add (separator);
            popover.add (games_box);
            popover.show_all ();
        }
        return popover;
    }

    public override void opened () {
        refresh.begin ();
    }

    public override void closed () {
    }

    /*
     * Built on open, never from a signal, so a game churning registrations
     * never wakes the panel. Names are resolved before the rows are swapped,
     * so overlapping refreshes just leave the last one's rows.
     */
    private async void refresh () {
        var games = yield client.list_games ();
        var dirs = Names.steamapps_dirs (Path.build_filename (Environment.get_user_data_dir (), "Steam", "steamapps"));
        string[] names = {};
        foreach (var game in games) {
            names += Names.display_name (game.executable, read_cmdline (game.pid), dirs);
        }
        message ("Game Mode games: %s", string.joinv (", ", names));

        if (games_box == null) {
            return;
        }
        games_box.foreach ((child) => child.destroy ());
        foreach (unowned string name in names) {
            games_box.add (new Gtk.Label (name) {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12,
                margin_top = 3,
                margin_bottom = 3,
                ellipsize = Pango.EllipsizeMode.END,
                max_width_chars = 32
            });
        }
        games_box.show_all ();
    }

    /* Null when the process is already gone. */
    private static string[]? read_cmdline (int pid) {
        uint8[] data;
        try {
            FileUtils.get_data ("/proc/%d/cmdline".printf (pid), out data);
        } catch (FileError e) {
            return null;
        }
        return Names.split_cmdline (data);
    }
}

public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.IndicatorManager.ServerType server_type) {
    // Nothing to show on the login screen, and no gamemoded there.
    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }
    return new GameModeIndicator.Indicator ();
}
