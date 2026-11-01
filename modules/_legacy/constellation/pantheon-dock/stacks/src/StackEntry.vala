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
    /* A folder of the Applications grid: its apps, A–Z. Null for anything else. */
    public ListStore? children { get; construct; }

    public bool is_folder { get { return children != null; } }

    /*
     * Busy state, shared by downloads and AppCenter jobs. A non-null
     * status_text ("Downloading · 34 MB", "Installing") marks the entry busy:
     * its icon is dimmed and the text shown. progress < 0 pulses.
     */
    public string? status_text { get; set; default = null; }
    public double progress { get; set; default = -1; }
    public bool show_progress { get; set; default = false; }

    /* A file that has not grown for this long is a leftover, not a download. */
    public const int64 STALL_USEC = 60 * 1000000;

    /* An in-progress download (.part, .crdownload, .download); `file` is the partial file. */
    public bool downloading { get; construct; default = false; }
    public uint64 bytes { get; set; }
    public bool stalled { get; set; }
    /* The AppCenter component of the job running on this entry, while one runs. */
    public string? job_component_id { get; set; default = null; }

    public void update_download (uint64 bytes, int64 modified_usec, int64 now_usec) {
        this.bytes = bytes;
        stalled = now_usec - modified_usec > STALL_USEC;
        var size = format_size (bytes);
        status_text = stalled ? _("Stalled · %s").printf (size) : _("Downloading · %s").printf (size);
        show_progress = !stalled;
        progress = -1;
    }

    public StackEntry (string name, Icon icon, File? file, AppInfo? app, int64 added_usec) {
        Object (name: name, icon: icon, file: file, app: app, added_usec: added_usec);
    }

    public static StackEntry from_file_info (File file, FileInfo info) {
        Icon icon = info.get_icon () ?? new ThemedIcon ("text-x-generic");
        var thumbnail = info.get_attribute_byte_string (FileAttribute.THUMBNAIL_PATH);
        if (thumbnail != null) {
            icon = new FileIcon (File.new_for_path (thumbnail));
        }

        var modified = (int64) info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED) * 1000000
            + info.get_attribute_uint32 (FileAttribute.TIME_MODIFIED_USEC);
        int64 added;
        if (info.has_attribute (FileAttribute.TIME_CREATED)) {
            added = (int64) info.get_attribute_uint64 (FileAttribute.TIME_CREATED) * 1000000
                + info.get_attribute_uint32 (FileAttribute.TIME_CREATED_USEC);
        } else {
            added = modified;
        }

        var name = info.get_display_name ();
        var suffix = StackSource.download_suffix (info.get_name ());
        if (suffix == null) {
            return new StackEntry (name, icon, file, null, added);
        }

        var entry = (StackEntry) Object.new (
            typeof (StackEntry),
            name: name.has_suffix (suffix) ? name.substring (0, name.length - suffix.length) : name,
            icon: icon,
            file: file,
            added_usec: added,
            downloading: true
        );
        entry.update_download (info.get_size (), modified, get_real_time ());
        return entry;
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

    public static StackEntry for_folder (string name, ListStore children) {
        return (StackEntry) Object.new (
            typeof (StackEntry),
            name: name,
            icon: new ThemedIcon ("folder"),
            children: children,
            added_usec: 0
        );
    }

    /* A cell for an app AppCenter is installing, before it has a desktop file. */
    public static StackEntry provisional (AppCenterJobs.Job job) {
        Icon? icon = null;
        if (job.icon != "") {
            try {
                icon = Icon.new_for_string (job.icon);
            } catch (Error e) {
                debug ("Bad icon from AppCenter for %s: %s", job.name, e.message);
            }
        }
        return new StackEntry (job.name, icon ?? new ThemedIcon ("application-default-icon"), null, null, 0);
    }

    public void launch () {
        if (is_folder) {
            // A folder opens inside the popover; GridPopover handles it.
            return;
        }
        if (job_component_id != null) {
            // Being installed, updated or removed: show it in AppCenter.
            open_uri ("appcenter://" + job_component_id);
            return;
        }
        if (app == null && file == null) {
            // A provisional cell whose install just ended; the pending reload replaces it.
            return;
        }
        if (downloading) {
            // Not done yet: show it in its folder instead of opening half a file.
            open_uri (file.get_parent ().get_uri ());
            return;
        }
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

    private static void open_uri (string uri) {
        try {
            AppInfo.launch_default_for_uri (uri, Gdk.Display.get_default ().get_app_launch_context ());
        } catch (Error e) {
            critical ("Failed to open %s: %s", uri, e.message);
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
            if (entry == null || entry.file == null || entry.downloading) {
                return null;
            }

            var value = Value (typeof (File));
            value.set_object (entry.file);
            return new Gdk.ContentProvider.for_value (value);
        });
        widget.add_controller (drag_source);
    }
}
