/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * A stack opened as a scrollable grid, like a macOS Grid stack.
 */

public class Dock.GridPopover : Gtk.Popover {
    private const int COLUMNS = 6;
    private const int VISIBLE_ROWS = 5;
    private const int CELL_WIDTH = 96;
    private const int CELL_HEIGHT = 100;
    private const int ICON_SIZE = 48;

    public StackSource source { get; construct; }

    private Gtk.Stack content;
    private Gtk.Label message;

    public GridPopover (StackSource source) {
        Object (source: source, position: Gtk.PositionType.TOP);
    }

    construct {
        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect ((obj) => {
            var list_item = (Gtk.ListItem) obj;

            var box = new Gtk.Box (VERTICAL, 6) {
                width_request = CELL_WIDTH,
                margin_top = 6,
                margin_bottom = 6
            };
            box.append (new Gtk.Image () { pixel_size = ICON_SIZE });
            box.append (new Gtk.Label (null) {
                ellipsize = END,
                max_width_chars = 12,
                justify = CENTER
            });

            StackEntry.attach_drag_source (box, () => (StackEntry?) list_item.item);
            list_item.child = box;
        });
        factory.bind.connect ((obj) => {
            var list_item = (Gtk.ListItem) obj;
            var entry = (StackEntry) list_item.item;
            var box = (Gtk.Box) list_item.child;
            ((Gtk.Image) box.get_first_child ()).gicon = entry.icon;
            ((Gtk.Label) box.get_last_child ()).label = entry.name;
        });

        var grid = new Gtk.GridView (new Gtk.NoSelection (source.entries), factory) {
            min_columns = COLUMNS,
            max_columns = COLUMNS,
            single_click_activate = true
        };
        grid.activate.connect ((position) => {
            var entry = (StackEntry) source.entries.get_item (position);
            popdown ();
            entry.launch ();
        });

        var scrolled = new Gtk.ScrolledWindow () {
            child = grid,
            hscrollbar_policy = NEVER,
            width_request = CELL_WIDTH * COLUMNS,
            max_content_height = CELL_HEIGHT * VISIBLE_ROWS,
            propagate_natural_height = true
        };

        message = new Gtk.Label (null) {
            margin_top = 24,
            margin_bottom = 24,
            margin_start = 24,
            margin_end = 24
        };
        message.add_css_class (Granite.STYLE_CLASS_DIM_LABEL);

        content = new Gtk.Stack ();
        content.add_named (scrolled, "grid");
        content.add_named (message, "message");
        child = content;

        // We need to set offset because dock window's height is 1px larger than its visible area
        set_offset (0, -1);

        // Methods, not capturing lambdas: a closure over a local would keep this
        // popover alive for as long as the source is.
        source.notify["missing"].connect (update_message);
        source.entries.items_changed.connect (update_message);
        update_message ();
    }

    ~GridPopover () {
        source.notify["missing"].disconnect (update_message);
        source.entries.items_changed.disconnect (update_message);
    }

    private void update_message () {
        if (source.missing) {
            message.label = _("Folder not found");
            content.visible_child_name = "message";
        } else if (source.entries.get_n_items () == 0) {
            message.label = _("No items");
            content.visible_child_name = "message";
        } else {
            content.visible_child_name = "grid";
        }
    }
}
