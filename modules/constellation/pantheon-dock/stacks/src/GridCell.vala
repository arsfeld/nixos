/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * One cell of a GridPopover: an app, a file, or a folder of apps, plus its
 * busy state. Grid cells are recycled, so `entry` changes and the bindings
 * follow it.
 */

public class Dock.GridCell : Gtk.Box {
    public const int ICON_SIZE = 48;
    private const int MINI_ICON_SIZE = 20;

    public StackEntry? entry { get; set; }
    /* Two lines of label: the text area's fixed height. */
    public int text_height { get; construct; }

    private Gtk.Stack icon_stack;
    private Gtk.Image image;
    private Gtk.Image[] mini_images = {};
    private Gtk.Revealer bar_revealer;
    private StackProgressBar bar;
    private Gtk.Label name_label;
    private Gtk.Label status_label;
    private GenericArray<Binding> bindings = new GenericArray<Binding> ();

    /* width: the cell's content width. */
    public GridCell (int width, int text_height) {
        Object (
            orientation: Gtk.Orientation.VERTICAL,
            spacing: 6,
            width_request: width,
            valign: Gtk.Align.START,
            text_height: text_height
        );
    }

    // Set-up lives in construct, not the creation method: valac runs only
    // property assignments for a GObject-style creation method's chain-up.
    construct {
        image = new Gtk.Image () { pixel_size = ICON_SIZE };
        image.add_css_class ("stack-icon");

        var mini_grid = new Gtk.Grid () {
            row_spacing = 4,
            column_spacing = 4,
            halign = CENTER,
            valign = CENTER,
            width_request = ICON_SIZE,
            height_request = ICON_SIZE
        };
        mini_grid.add_css_class ("stack-folder-icon");
        for (int i = 0; i < 4; i++) {
            var mini = new Gtk.Image () { pixel_size = MINI_ICON_SIZE };
            mini_grid.attach (mini, i % 2, i / 2);
            mini_images += mini;
        }

        icon_stack = new Gtk.Stack () { halign = CENTER };
        icon_stack.add_named (image, "icon");
        icon_stack.add_named (mini_grid, "folder");

        bar_revealer = StackBusy.new_bar_revealer (out bar);
        var icon = new Gtk.Overlay () { child = icon_stack, halign = CENTER };
        icon.add_overlay (bar_revealer);
        append (icon);

        // Wraps to two lines before ellipsizing; width_chars keeps every
        // cell's label the same width, so the columns stay aligned.
        name_label = new Gtk.Label (null) {
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            lines = 2,
            ellipsize = END,
            width_chars = 12,
            max_width_chars = 12,
            justify = CENTER,
            yalign = 0
        };
        status_label = new Gtk.Label (null) {
            ellipsize = END,
            max_width_chars = 12,
            visible = false
        };
        status_label.add_css_class ("stack-status");

        // Two lines tall whatever is in it, so all rows are the same height.
        var text = new Gtk.Box (VERTICAL, 0) { height_request = text_height, valign = START };
        text.append (name_label);
        text.append (status_label);
        append (text);

        notify["entry"].connect (rebind);
        attach_drag (this);
    }

    // Static, so the getter cannot capture `this`: the cell owns the drag
    // source, and a closure over the cell would keep it alive forever.
    private static void attach_drag (GridCell cell) {
        unowned var weak_cell = cell;
        StackEntry.attach_drag_source (cell, () => weak_cell.entry);
    }

    private void rebind () {
        foreach (var binding in bindings) {
            binding.unbind ();
        }
        bindings.length = 0;

        if (entry == null) {
            return;
        }

        if (entry.is_folder) {
            var n = entry.children.get_n_items ();
            for (uint i = 0; i < mini_images.length; i++) {
                mini_images[i].gicon = i < n ? ((StackEntry) entry.children.get_item (i)).icon : null;
            }
            icon_stack.visible_child_name = "folder";
            name_label.label = "%s · %u".printf (entry.name, n);
        } else {
            image.gicon = entry.icon;
            icon_stack.visible_child_name = "icon";
            name_label.label = entry.name;
        }

        StackBusy.bind (entry, icon_stack, status_label, bar_revealer, bar, bindings);
        // A busy cell gives its second line to the status.
        bindings.add (entry.bind_property ("status-text", name_label, "lines", SYNC_CREATE, busy_to_lines));
    }

    private static bool busy_to_lines (Binding binding, Value from, ref Value to) {
        to.set_int (from.get_string () != null ? 1 : 2);
        return true;
    }
}
