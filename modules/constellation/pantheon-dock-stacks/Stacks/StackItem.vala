/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * A folder stack on the dock: a live 2×2 preview of the newest entries (or a
 * plain folder icon), opening as a fan or a grid.
 */

public class Dock.StackItem : BaseIconGroup {
    public StackConfig config { get; construct; }
    public StackSource source { get; construct; }

    private Gtk.Widget preview;
    private Gtk.Image folder_image;

    public StackItem (StackConfig config) {
        var source = new StackSource (config);
        Object (
            config: config,
            source: source,
            icons: new Gtk.MapListModel (source.entries, (entry) => {
                return ((StackEntry) entry).icon;
            }),
            group: Group.NONE
        );
    }

    construct {
        // BaseIconGroup has already set child to its icon grid.
        preview = child;

        folder_image = new Gtk.Image.from_gicon (folder_icon ());
        bind_property ("icon-size", folder_image, "pixel-size", SYNC_CREATE);

        tooltip_text = config.is_applications ? _("Applications") : Path.get_basename (config.source);

        popover_menu = create_popover ();
        popover_menu.set_parent (this);

        gesture_click.released.connect (() => popover_menu.popup ());

        // Methods, not capturing lambdas, so the source never keeps this item alive.
        source.notify["missing"].connect (update_child);
        source.entries.items_changed.connect (update_child);
        update_child ();
    }

    ~StackItem () {
        source.notify["missing"].disconnect (update_child);
        source.entries.items_changed.disconnect (update_child);
        popover_menu.unparent ();
        popover_menu.dispose ();
    }

    // Task 4 replaces this with a switch on config.view.
    private Gtk.Popover create_popover () {
        return new GridPopover (source);
    }

    private void update_child () {
        var empty = source.missing || source.entries.get_n_items () == 0;
        Gtk.Widget wanted = (config.display == FOLDER || empty) ? folder_image : preview;
        if (child != wanted) {
            child = wanted;
        }
        folder_image.opacity = source.missing ? 0.5 : 1.0;
    }

    private Icon folder_icon () {
        if (config.is_applications) {
            return new ThemedIcon ("applications-other");
        }
        if (config.source == Environment.get_user_special_dir (DOWNLOAD)) {
            return new ThemedIcon ("folder-download");
        }
        try {
            var info = File.new_for_path (config.source).query_info (FileAttribute.STANDARD_ICON, NONE);
            return info.get_icon () ?? new ThemedIcon ("folder");
        } catch (Error e) {
            return new ThemedIcon ("folder");
        }
    }
}
