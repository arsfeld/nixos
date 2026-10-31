/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * A stack opened as a scrollable grid, like a macOS Grid stack.
 */

public class Dock.GridPopover : Gtk.Popover {
    private const int COLUMNS = 6;
    private const int VISIBLE_ROWS = 4;
    private const int ICON_SIZE = 48;
    private const int SPACING = 6;
    // A cell's content box. StackStyle adds the cell's padding (9px top, 6px
    // elsewhere) and its 3px margin around it; keep these sums in step with it.
    private const int CELL_WIDTH = 100;
    private const int CELL_EXTRA_WIDTH = 2 * (6 + 3);
    private const int CELL_EXTRA_HEIGHT = 9 + 6 + 2 * 3;

    public StackSource source { get; construct; }

    private Gtk.Stack content;
    private Gtk.Label message;

    public GridPopover (StackSource source) {
        Object (source: source, position: Gtk.PositionType.TOP);
    }

    construct {
        StackStyle.ensure ();
        add_css_class ("stack-grid");

        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect ((obj) => {
            var list_item = (Gtk.ListItem) obj;

            var box = new Gtk.Box (VERTICAL, SPACING) {
                width_request = CELL_WIDTH,
                valign = START
            };
            var image = new Gtk.Image () { pixel_size = ICON_SIZE };
            image.add_css_class ("stack-icon");
            box.append (image);
            // Wraps to two lines before ellipsizing; width_chars keeps every
            // cell's label the same width, so the columns stay aligned.
            box.append (new Gtk.Label (null) {
                wrap = true,
                wrap_mode = Pango.WrapMode.WORD_CHAR,
                lines = 2,
                ellipsize = END,
                width_chars = 12,
                max_width_chars = 12,
                justify = CENTER,
                valign = START,
                yalign = 0,
                // Two lines tall even for a one-line name, so all rows are the same height.
                height_request = two_line_height ()
            });

            // unowned: a strong capture would form list_item -> box -> drag source -> list_item.
            unowned var cell = list_item;
            StackEntry.attach_drag_source (box, () => (StackEntry?) cell.item);
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
        grid.activate.connect (on_activate);

        var scrolled = new Gtk.ScrolledWindow () {
            child = grid,
            hscrollbar_policy = NEVER,
            width_request = (CELL_WIDTH + CELL_EXTRA_WIDTH) * COLUMNS,
            // Whole rows only: a row cut through its labels looks broken, not scrollable.
            max_content_height = (ICON_SIZE + SPACING + two_line_height () + CELL_EXTRA_HEIGHT) * VISIBLE_ROWS,
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

    private static int label_height = 0;

    /* The height of a two-line label in the current font. */
    private static int two_line_height () {
        if (label_height == 0) {
            var probe = new Gtk.Label ("X\nX");
            int min, nat, min_b, nat_b;
            probe.measure (VERTICAL, -1, out min, out nat, out min_b, out nat_b);
            label_height = nat;
        }
        return label_height;
    }

    private void on_activate (uint position) {
        var entry = (StackEntry) source.entries.get_item (position);
        popdown ();
        entry.launch ();
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
