/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * A stack opened as a fan: the newest MAX_ITEMS entries on an arc, newest
 * nearest the dock, with "Open in Files" and "N more…" above.
 */

public class Dock.FanPopover : Gtk.Popover {
    public const int MAX_ITEMS = 10;
    private const int ICON_SIZE = 48;

    public StackSource source { get; construct; }

    private FanLayout fan;
    private Gtk.Button more_button;
    private Gtk.Label message;

    public FanPopover (StackSource source) {
        Object (source: source, position: Gtk.PositionType.TOP, has_arrow: false);
    }

    construct {
        StackStyle.ensure ();
        add_css_class ("stack-fan");

        var open_button = create_pill_button (_("Open in Files"));
        open_button.clicked.connect (open_location);

        more_button = create_pill_button ("");
        more_button.clicked.connect (open_location);

        message = new Gtk.Label (null) {
            halign = END
        };
        message.add_css_class ("stack-fan-label");

        fan = new FanLayout () {
            margin_start = 24,
            margin_top = 12
        };

        var box = new Gtk.Box (VERTICAL, 6) {
            halign = END
        };
        box.append (open_button);
        box.append (more_button);
        box.append (message);
        box.append (fan);
        child = box;

        // We need to set offset because dock window's height is 1px larger than its visible area
        set_offset (0, -1);

        // Methods, not capturing lambdas: a closure would keep this popover alive
        // for as long as the source is.
        source.entries.items_changed.connect (rebuild);
        source.notify["missing"].connect (rebuild);
        rebuild ();
    }

    ~FanPopover () {
        debug ("FanPopover finalized for %s", source.config.source);
        source.entries.items_changed.disconnect (rebuild);
        source.notify["missing"].disconnect (rebuild);
    }

    private static Gtk.Button create_pill_button (string label) {
        var pill = new Gtk.Label (label);
        pill.add_css_class ("stack-fan-label");

        var button = new Gtk.Button () {
            child = pill,
            halign = END
        };
        button.add_css_class ("stack-fan-item");
        return button;
    }

    private void open_location () {
        popdown ();
        source.open_location ();
    }

    private void rebuild () {
        fan.clear ();

        var total = source.entries.get_n_items ();
        var shown = uint.min (total, MAX_ITEMS);
        for (uint i = 0; i < shown; i++) {
            fan.append_row (create_row ((StackEntry) source.entries.get_item (i)));
        }

        var extra = total - shown;
        more_button.visible = extra > 0;
        ((Gtk.Label) more_button.child).label = _("%u more…").printf (extra);

        message.visible = source.missing || total == 0;
        message.label = source.missing ? _("Folder not found") : _("No items");
    }

    // Static so its lambdas cannot capture `this`: the popover owns the button
    // (through the fan), so a closure holding the popover would form a cycle that
    // keeps it, and through it the source, alive after StackItem tears down.
    private static Gtk.Widget create_row (StackEntry entry) {
        var label = new Gtk.Label (entry.name) {
            ellipsize = MIDDLE,
            max_width_chars = 28
        };
        label.add_css_class ("stack-fan-label");

        var box = new Gtk.Box (HORIZONTAL, 8);
        box.append (label);
        box.append (new Gtk.Image.from_gicon (entry.icon) { pixel_size = ICON_SIZE });

        var button = new Gtk.Button () {
            child = box,
            tooltip_text = entry.name
        };
        button.add_css_class ("stack-fan-item");
        button.clicked.connect ((b) => {
            var popover = (Gtk.Popover?) b.get_ancestor (typeof (Gtk.Popover));
            if (popover != null) {
                popover.popdown ();
            }
            entry.launch ();
        });
        StackEntry.attach_drag_source (button, () => entry);
        return button;
    }
}
