/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * A stack opened as a fan: the newest MAX_ITEMS entries in a column curving
 * up from the dock, newest at the bottom, topped by "Open in Files" (or
 * "N more in Files" when the folder holds more).
 */

public class Dock.FanPopover : Gtk.Popover {
    public const int MAX_ITEMS = 10;
    private const int HEADER_ICON_SIZE = 32;

    public StackSource source { get; construct; }

    private FanLayout fan;
    private Gtk.Button header;
    private Gtk.Label header_label;
    private Gtk.Widget message;
    private Gtk.Label message_label;
    // Rows are rebuilt only when the popover is shown: rebuilding while it is
    // closed would be wasted work, and rebuilding while it is open destroys the
    // button that owns an in-flight drag.
    private bool dirty = true;

    public FanPopover (StackSource source) {
        Object (source: source, position: Gtk.PositionType.TOP, has_arrow: false);
    }

    construct {
        StackStyle.ensure ();
        add_css_class ("stack-fan");

        header_label = new Gtk.Label (null);
        header = new Gtk.Button () {
            child = create_row_box (header_label, new Gtk.Image.from_gicon (source.folder_icon ()) {
                pixel_size = HEADER_ICON_SIZE
            })
        };
        header.add_css_class ("stack-fan-item");
        header.clicked.connect (open_location);

        // A row with no icon: the empty image keeps its label in line with the others.
        message_label = new Gtk.Label (null);
        message = create_row_box (message_label, new Gtk.Image ());

        fan = new FanLayout ();
        child = fan;

        // We need to set offset because dock window's height is 1px larger than its visible area
        set_offset (0, -1);

        // Methods, not capturing lambdas: a closure would keep this popover alive
        // for as long as the source is.
        source.entries.items_changed.connect (mark_dirty);
        source.notify["missing"].connect (mark_dirty);
    }

    ~FanPopover () {
        debug ("FanPopover finalized for %s", source.config.source);
        source.entries.items_changed.disconnect (mark_dirty);
        source.notify["missing"].disconnect (mark_dirty);
    }

    // Label pill on the left, icon on the right, in an icon-wide slot so every
    // row's icon lands in the same column.
    private static Gtk.Box create_row_box (Gtk.Label label, Gtk.Image image) {
        label.add_css_class ("stack-fan-label");
        label.valign = CENTER;

        image.add_css_class ("stack-icon");
        image.width_request = FanLayout.ICON_SIZE;
        image.halign = CENTER;
        image.valign = CENTER;

        var box = new Gtk.Box (HORIZONTAL, 8);
        box.append (label);
        box.append (image);
        return box;
    }

    private void open_location () {
        popdown ();
        source.open_location ();
    }

    private void mark_dirty () {
        dirty = true;
    }

    // Rebuild before chaining up, not on notify::visible: GtkPopover's show
    // handler moves focus into the popover's children, and notify::visible only
    // fires after it. Rebuilding there left the fan empty at that moment, so the
    // focus move failed and GTK called gtk_widget_is_ancestor (NULL, ...) on the
    // dock window's NULL focus: a critical on first open. A click pops up
    // through this same show path.
    public override void show () {
        if (dirty) {
            rebuild ();
        }
        base.show ();
    }

    private void rebuild () {
        dirty = false;
        fan.clear ();

        var total = source.entries.get_n_items ();
        var shown = uint.min (total, MAX_ITEMS);
        for (uint i = 0; i < shown; i++) {
            fan.append_row (create_row ((StackEntry) source.entries.get_item (i)));
        }

        if (source.missing || total == 0) {
            message_label.label = source.missing ? _("Folder not found") : _("No items");
            fan.append_row (message);
        }

        var extra = total - shown;
        header_label.label = extra > 0 ? _("%u more in Files").printf (extra) : _("Open in Files");
        fan.append_row (header);
    }

    // Static so its lambdas cannot capture `this`: the popover owns the button
    // (through the fan), so a closure holding the popover would form a cycle that
    // keeps it, and through it the source, alive after StackItem tears down.
    private static Gtk.Widget create_row (StackEntry entry) {
        var label = new Gtk.Label (entry.name) {
            ellipsize = MIDDLE,
            max_width_chars = 28
        };

        var button = new Gtk.Button () {
            child = create_row_box (label, new Gtk.Image.from_gicon (entry.icon) { pixel_size = FanLayout.ICON_SIZE }),
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
