/*
 * Tailscale in Wingpanel: an icon for tailscaled's state, always shown, and a
 * popover with an on/off switch, the node's IPv4, an exit-node picker and any
 * health warnings.
 *
 * Every change of state logs one line ("Tailscale: <Model.describe>") and every
 * /status fetch logs "Tailscale status: <n> exit node candidate(s)" or
 * "Tailscale status: unavailable"; the VM test
 * (tests/pantheon-tailscale-test.nix) asserts on them, so keep them stable.
 *
 * Controls show only what the IPN bus reports: a write never moves them, so a
 * refused one snaps back when the popover is resynced.
 */
public class TailscaleIndicator.Indicator : Wingpanel.Indicator {
    private const string ICONS = "/io/elementary/wingpanel/tailscale/icons";

    private State state;
    private LocalApi api;
    // The last /status: exit-node names and the IPv4. Empty until the first fetch.
    private Status status = new Status ();
    private string last_logged = "";
    private Backend last_backend = Backend.UNREACHABLE;
    private string last_exit = "";

    private Gtk.Image? icon = null;
    private Gtk.Box? popover = null;
    private Granite.SwitchModelButton? toggle = null;
    private Gtk.Label? error_label = null;
    private Gtk.Label? status_label = null;
    private Gtk.Box? exit_box = null;
    private Gtk.Box? health_box = null;
    // Set while widgets are moved to match tailscaled, so their handlers write nothing.
    private bool syncing = false;

    public Indicator () {
        Object (code_name: "tailscale");
    }

    construct {
        Gtk.IconTheme.get_default ().add_resource_path (ICONS);
        state = new State ();
        state.notify.connect (on_state_changed);
        api = new LocalApi (state);
        visible = true;
    }

    /*
     * Refetches /status when Tailscale comes up or the exit node changes, so
     * the log line and icon tooltip can name the exit node without the popover.
     */
    private void on_state_changed () {
        if ((state.backend == Backend.RUNNING && last_backend != Backend.RUNNING) || state.exit_node_id != last_exit) {
            refresh.begin ();
        }
        last_backend = state.backend;
        last_exit = state.exit_node_id;
        update ();
    }

    private void update () {
        var line = Model.describe (state, exit_name ());
        if (line != last_logged) {
            last_logged = line;
            message ("Tailscale: %s", line);
        }
        if (icon != null) {
            icon.icon_name = Model.icon_name (state);
            icon.tooltip_text = "Tailscale: " + Model.status_line (state, status.ipv4);
        }
        sync_popover ();
    }

    private string? exit_name () {
        return state.exit_node_id == "" ? null : Model.exit_node_name (state.exit_node_id, status.exit_nodes);
    }

    public override Gtk.Widget get_display_widget () {
        if (icon == null) {
            icon = new Gtk.Image.from_icon_name (Model.icon_name (state), Gtk.IconSize.LARGE_TOOLBAR) {
                tooltip_text = "Tailscale"
            };
        }
        return icon;
    }

    public override Gtk.Widget? get_widget () {
        if (popover == null) {
            toggle = new Granite.SwitchModelButton ("Tailscale");
            toggle.get_style_context ().add_class (Granite.STYLE_CLASS_H4_LABEL);
            toggle.notify["active"].connect (() => {
                if (!syncing) {
                    write.begin (true, toggle.active, "");
                }
            });

            error_label = new Gtk.Label (null) {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12,
                wrap = true,
                max_width_chars = 32,
                no_show_all = true
            };
            error_label.get_style_context ().add_class (Gtk.STYLE_CLASS_ERROR);

            status_label = new Gtk.Label (null) {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12,
                margin_bottom = 3,
                selectable = true
            };
            status_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);

            exit_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            health_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                margin_bottom = 3
            };

            popover = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                width_request = 250
            };
            popover.add (toggle);
            popover.add (error_label);
            popover.add (status_label);
            popover.add (exit_box);
            popover.add (health_box);
            popover.show_all ();
            sync_popover ();
        }
        return popover;
    }

    public override void opened () {
        refresh.begin ();
    }

    public override void closed () {
        if (error_label != null) {
            error_label.hide ();
        }
    }

    private async void refresh () {
        var fetched = yield api.status ();
        if (fetched == null) {
            message ("Tailscale status: unavailable");
            status = new Status ();
        } else {
            status = fetched;
            message ("Tailscale status: %d exit node candidate(s)", status.exit_nodes.length);
        }
        update ();
    }

    /* running: whether this write is the switch (on) or the exit node (exit_id). */
    private async void write (bool running, bool on, string exit_id) {
        uint code;
        if (running) {
            code = yield api.set_running (on);
        } else {
            code = yield api.set_exit_node (exit_id);
        }
        if (error_label == null) {
            return;
        }
        if (code >= 200 && code < 300) {
            error_label.hide ();
        } else {
            error_label.label = Model.write_error_text (code);
            error_label.show ();
            sync_popover ();
        }
    }

    /* Rebuilt from state and the last /status; never writes. */
    private void sync_popover () {
        if (popover == null) {
            return;
        }
        syncing = true;
        var reachable = state.backend != Backend.UNREACHABLE;
        toggle.sensitive = reachable;
        toggle.active = reachable && state.want_running;
        status_label.label = Model.status_line (state, status.ipv4);

        exit_box.foreach ((child) => child.destroy ());
        if (state.backend == Backend.RUNNING && status.exit_nodes.length > 0) {
            exit_box.add (new Gtk.Separator (Gtk.Orientation.HORIZONTAL) {
                margin_top = 3,
                margin_bottom = 3
            });
            var header = new Gtk.Label ("Exit node") {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12
            };
            header.get_style_context ().add_class (Granite.STYLE_CLASS_H4_LABEL);
            exit_box.add (header);
            var group = exit_row (null, "", "None", true);
            foreach (var node in status.exit_nodes) {
                exit_row (group, node.id, node.online ? node.name : node.name + " (offline)", node.online);
            }
        }
        exit_box.show_all ();

        health_box.foreach ((child) => child.destroy ());
        foreach (unowned string text in status.health) {
            var label = new Gtk.Label (text) {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12,
                margin_top = 3,
                wrap = true,
                max_width_chars = 32
            };
            label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
            health_box.add (label);
        }
        health_box.show_all ();
        syncing = false;
    }

    private Gtk.RadioButton exit_row (Gtk.RadioButton? group, string id, string label, bool sensitive) {
        var row = new Gtk.RadioButton.with_label_from_widget (group, label) {
            sensitive = sensitive,
            margin_start = 12,
            margin_end = 12,
            margin_top = 3,
            margin_bottom = 3
        };
        row.active = state.exit_node_id == id;
        // The handler's own argument, not `row`: capturing `row` would make the
        // button own a closure that owns the button, and it could never be freed.
        row.toggled.connect ((button) => {
            if (!syncing && button.active) {
                write.begin (false, false, id);
            }
        });
        exit_box.add (row);
        return row;
    }
}

public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.IndicatorManager.ServerType server_type) {
    // Nothing to control from the login screen.
    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }
    return new TailscaleIndicator.Indicator ();
}
