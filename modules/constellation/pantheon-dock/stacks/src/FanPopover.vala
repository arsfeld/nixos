/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * A stack opened as a fan: the newest MAX_ITEMS entries in a column curving
 * up from the dock, newest at the bottom, topped by "Open in Files" (or
 * "N more in Files" when the folder holds more). A click zooms the row's icon
 * away and folds the rest back into the tile (FanLayout.collapse) before the
 * fan closes.
 */

public class Dock.FanPopover : Gtk.Popover {
    public const int MAX_ITEMS = FanMath.MAX_ITEMS;
    private const int HEADER_ICON_SIZE = 32;
    // How long a clicked row takes to zoom away while the rest fold into the tile.
    private const uint LAUNCH_MS = 250;

    public StackSource source { get; construct; }

    private FanLayout fan;
    private Gtk.Button header;
    private Gtk.Label header_label;
    private Gtk.Widget message;
    private Adw.TimedAnimation launch_animation;
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

        // The target holds the fan, not this popover, so the animation forms no cycle.
        launch_animation = new Adw.TimedAnimation (fan, 0, 1, LAUNCH_MS, new Adw.PropertyAnimationTarget (fan, "collapse")) {
            easing = EASE_OUT_CUBIC
        };
        launch_animation.done.connect (popdown);
        closed.connect (on_closed);

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
        if (launch_row (header)) {
            source.open_location ();
        }
    }

    /*
     * Zooms row's icon away and folds the rest of the fan into the tile, then
     * closes. The caller opens the file itself, right away: nothing waits on this.
     * Returns false, and the caller opens nothing, when a launch is already
     * playing: can_target stops a second click, but not Enter on the focused row.
     */
    private bool launch_row (Gtk.Widget row) {
        if (launch_animation.state == PLAYING) {
            return false;
        }
        fan.start_launch (row, row_icon (row));
        launch_animation.play ();
        source.launched ();
        return true;
    }

    // Every row is a button around create_row_box (), whose last child is the icon.
    private static Gtk.Widget row_icon (Gtk.Widget row) {
        return ((Gtk.Button) row).child.get_last_child ();
    }

    private void on_closed () {
        launch_animation.reset ();
        fan.reset_launch ();
    }

    /*
     * Test hook for DOCK_STACKS_CLICK (see StackItem): plays row's launch
     * without opening anything, or, with progress in 0–1, holds the fan at that
     * point of it so a screenshot can catch it.
     */
    public void launch_for_test (uint row, double progress) {
        var widget = fan.row_at (row);
        if (widget == null) {
            warning ("DOCK_STACKS_CLICK: no row %u", row);
            return;
        }
        if (progress < 0) {
            launch_row (widget);
            return;
        }
        fan.start_launch (widget, row_icon (widget));
        fan.collapse = progress;
        source.launched ();
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
            var popover = (FanPopover?) b.get_ancestor (typeof (FanPopover));
            if (popover != null && !popover.launch_row (b)) {
                return;
            }
            entry.launch ();
        });
        StackEntry.attach_drag_source (button, () => entry);
        return button;
    }
}
