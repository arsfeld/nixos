/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * One thing in a stack: a file in a folder, or an installed app.
 */

public class Dock.StackEntry : Object {
    public delegate StackEntry? Getter ();

    public string name { get; construct; }
    public Icon icon { get; construct; }
    public File? file { get; construct; }
    public AppInfo? app { get; construct; }
    /* Sort key for date-added: creation time, or modification time where the filesystem has none. */
    public int64 added_usec { get; construct; }

    public StackEntry (string name, Icon icon, File? file, AppInfo? app, int64 added_usec) {
        Object (name: name, icon: icon, file: file, app: app, added_usec: added_usec);
    }

    public static StackEntry from_file_info (File file, FileInfo info) {
        Icon icon = info.get_icon () ?? new ThemedIcon ("text-x-generic");
        var thumbnail = info.get_attribute_byte_string (FileAttribute.THUMBNAIL_PATH);
        if (thumbnail != null) {
            icon = new FileIcon (File.new_for_path (thumbnail));
        }

        int64 added;
        if (info.has_attribute (FileAttribute.TIME_CREATED)) {
            added = (int64) info.get_attribute_uint64 (FileAttribute.TIME_CREATED) * 1000000
                + info.get_attribute_uint32 (FileAttribute.TIME_CREATED_USEC);
        } else {
            added = (int64) info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED) * 1000000
                + info.get_attribute_uint32 (FileAttribute.TIME_MODIFIED_USEC);
        }

        return new StackEntry (info.get_display_name (), icon, file, null, added);
    }

    public static StackEntry from_app (AppInfo app) {
        return new StackEntry (
            app.get_display_name (),
            app.get_icon () ?? new ThemedIcon ("application-default-icon"),
            null,
            app,
            0
        );
    }

    public void launch () {
        var context = Gdk.Display.get_default ().get_app_launch_context ();
        try {
            if (app != null) {
                app.launch (null, context);
            } else {
                AppInfo.launch_default_for_uri (file.get_uri (), context);
            }
        } catch (Error e) {
            critical ("Failed to open %s: %s", name, e.message);
        }
    }

    /*
     * Lets a file entry be dragged out of a popover (into a browser upload, a
     * mail, Files). get_entry is called at drag time, so recycled grid cells
     * always drag the entry they currently show.
     */
    public static void attach_drag_source (Gtk.Widget widget, owned Getter get_entry) {
        var drag_source = new Gtk.DragSource () {
            actions = COPY
        };
        drag_source.prepare.connect ((x, y) => {
            var entry = get_entry ();
            if (entry == null || entry.file == null) {
                return null;
            }

            var value = Value (typeof (File));
            value.set_object (entry.file);
            return new Gdk.ContentProvider.for_value (value);
        });
        widget.add_controller (drag_source);
    }
}
