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
    private Gtk.GridView folder_grid;
    private Gtk.Label folder_title;

    public GridPopover (StackSource source) {
        Object (source: source, position: Gtk.PositionType.TOP);
    }

    construct {
        StackStyle.ensure ();
        add_css_class ("stack-grid");

        var grid = create_grid (source.entries);
        grid.activate.connect (on_activate);

        folder_grid = create_grid (null);
        folder_grid.activate.connect (on_folder_activate);

        var back = new Gtk.Button.with_label (_("Applications")) {
            halign = START
        };
        back.add_css_class ("back-button");
        back.clicked.connect (close_folder);

        folder_title = new Gtk.Label (null) {
            hexpand = true,
            xalign = 0
        };
        folder_title.add_css_class ("title-4");

        var header = new Gtk.Box (HORIZONTAL, 12) {
            margin_bottom = 6
        };
        header.append (back);
        header.append (folder_title);

        var folder_page = new Gtk.Box (VERTICAL, 0);
        folder_page.append (header);
        folder_page.append (create_scrolled (folder_grid));

        message = new Gtk.Label (null) {
            margin_top = 24,
            margin_bottom = 24,
            margin_start = 24,
            margin_end = 24
        };
        message.add_css_class (Granite.STYLE_CLASS_DIM_LABEL);

        content = new Gtk.Stack () {
            vhomogeneous = false,
            transition_type = SLIDE_LEFT_RIGHT
        };
        content.add_named (create_scrolled (grid), "grid");
        content.add_named (folder_page, "folder");
        content.add_named (message, "message");
        child = content;

        // Escape inside a folder goes back to the top level instead of closing.
        // Capture phase: the popover's own Escape shortcut would win otherwise.
        var keys = new Gtk.EventControllerKey () {
            propagation_phase = CAPTURE
        };
        keys.key_pressed.connect (on_key_pressed);
        ((Gtk.Widget) this).add_controller (keys);
        closed.connect (on_closed);

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

    private static Gtk.GridView create_grid (ListModel? model) {
        var factory = new Gtk.SignalListItemFactory ();
        factory.setup.connect (setup_cell);
        factory.bind.connect (bind_cell);
        factory.unbind.connect (unbind_cell);

        return new Gtk.GridView (model == null ? null : new Gtk.NoSelection (model), factory) {
            min_columns = COLUMNS,
            max_columns = COLUMNS,
            single_click_activate = true
        };
    }

    private static Gtk.ScrolledWindow create_scrolled (Gtk.GridView grid) {
        return new Gtk.ScrolledWindow () {
            child = grid,
            hscrollbar_policy = NEVER,
            width_request = (CELL_WIDTH + CELL_EXTRA_WIDTH) * COLUMNS,
            // Whole rows only: a row cut through its labels looks broken, not scrollable.
            max_content_height = (ICON_SIZE + SPACING + two_line_height () + CELL_EXTRA_HEIGHT) * VISIBLE_ROWS,
            propagate_natural_height = true
        };
    }

    private static void setup_cell (Object obj) {
        ((Gtk.ListItem) obj).child = new GridCell (CELL_WIDTH, two_line_height ());
    }

    private static void bind_cell (Object obj) {
        var list_item = (Gtk.ListItem) obj;
        ((GridCell) list_item.child).entry = (StackEntry) list_item.item;
    }

    private static void unbind_cell (Object obj) {
        ((GridCell) ((Gtk.ListItem) obj).child).entry = null;
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
        activate_entry ((StackEntry) source.entries.get_item (position));
    }

    private void on_folder_activate (uint position) {
        activate_entry ((StackEntry) folder_grid.model.get_item (position));
    }

    private void activate_entry (StackEntry entry) {
        if (entry.is_folder) {
            open_folder (entry);
            return;
        }
        popdown ();
        source.launched ();
        entry.launch ();
    }

    private void open_folder (StackEntry folder) {
        folder_grid.model = new Gtk.NoSelection (folder.children);
        folder_title.label = folder.name;
        content.visible_child_name = "folder";
    }

    private void close_folder () {
        content.visible_child_name = "grid";
    }

    private bool on_key_pressed (uint keyval, uint keycode, Gdk.ModifierType state) {
        if (keyval == Gdk.Key.Escape && content.visible_child_name == "folder") {
            close_folder ();
            return true;
        }
        return false;
    }

    // Reopening always starts at the top level, without a slide.
    private void on_closed () {
        content.transition_type = NONE;
        close_folder ();
        update_message ();
        content.transition_type = SLIDE_LEFT_RIGHT;
    }

    /* Test hook for DOCK_STACKS_FOLDER (see StackItem). */
    public void open_folder_for_test (string name) {
        var folder = find_folder (name);
        if (folder == null) {
            warning ("DOCK_STACKS_FOLDER: no folder '%s'", name);
            return;
        }
        open_folder (folder);
    }

    private StackEntry? find_folder (string name) {
        for (uint i = 0; i < source.entries.get_n_items (); i++) {
            var entry = (StackEntry) source.entries.get_item (i);
            if (entry.is_folder && entry.name == name) {
                return entry;
            }
        }
        return null;
    }

    private void update_message () {
        if (source.missing) {
            message.label = _("Folder not found");
            content.visible_child_name = "message";
        } else if (source.entries.get_n_items () == 0) {
            message.label = _("No items");
            content.visible_child_name = "message";
        } else if (content.visible_child_name == "folder" && get_mapped ()) {
            // A reload replaced the folder entries: follow the open folder to its
            // new object, or go back if it emptied.
            var folder = find_folder (folder_title.label);
            if (folder != null) {
                open_folder (folder);
            } else {
                content.visible_child_name = "grid";
            }
        } else {
            content.visible_child_name = "grid";
        }
    }
}
