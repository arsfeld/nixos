/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The live, sorted contents of one stack: a folder watched with a
 * FileMonitor, or every app that should be shown.
 */

public class Dock.StackSource : Object {
    private const string FILE_ATTRIBUTES = "standard::name,standard::display-name,standard::icon," +
        "standard::is-hidden,standard::is-backup,time::created,time::created-usec," +
        "time::modified,time::modified-usec,thumbnail::path";
    // Downloads arrive as bursts of events (create, write, rename); reload once per burst.
    private const uint RELOAD_DELAY_MS = 200;

    public signal void loaded ();

    /*
     * Emitted when an entry, or the folder itself, is opened from one of this
     * source's popovers, so the dock tile can bounce.
     */
    public signal void launched ();

    public StackConfig config { get; construct; }
    public ListModel entries { get { return store; } }
    /* The top-level entries that are not folders, for the tile's preview. */
    public ListModel previews { get { return preview_store; } }
    /* Applications shown as a grid are grouped into AppFolders. */
    public bool groups_folders { get { return config.is_applications && config.view == GRID; } }
    public bool missing { get; private set; default = false; }

    private ListStore store;
    private ListStore preview_store;
    private FileMonitor? monitor;
    private AppInfoMonitor? app_monitor;
    private Cancellable? cancellable;
    private uint reload_id = 0;

    public StackSource (StackConfig config) {
        Object (config: config);
    }

    construct {
        store = new ListStore (typeof (StackEntry));
        preview_store = new ListStore (typeof (StackEntry));

        if (config.is_applications) {
            app_monitor = AppInfoMonitor.get ();
            app_monitor.changed.connect (queue_reload);
        } else {
            try {
                monitor = File.new_for_path (config.source).monitor_directory (WATCH_MOVES, null);
                monitor.changed.connect (on_monitor_changed);
            } catch (Error e) {
                debug ("Not watching %s: %s", config.source, e.message);
            }
        }

        // Deferred so callers can connect to `loaded` before the first load.
        queue_reload ();
    }

    public override void dispose () {
        stop ();
        base.dispose ();
    }

    /* Stops watching and reloading. Idempotent. */
    public void stop () {
        debug ("StackSource stop for %s", config.source);
        if (monitor != null) {
            monitor.cancel ();
            monitor = null;
        }
        if (app_monitor != null) {
            // AppInfoMonitor is a shared singleton that outlives this source.
            app_monitor.changed.disconnect (queue_reload);
            app_monitor = null;
        }
        if (reload_id != 0) {
            Source.remove (reload_id);
            reload_id = 0;
        }
        if (cancellable != null) {
            cancellable.cancel ();
            cancellable = null;
        }
        // Frees the entries (and their icons) even if the owner is leaked.
        store.remove_all ();
        preview_store.remove_all ();
    }

    public static bool is_shown_name (string name) {
        return !name.has_prefix (".")
            && !name.has_suffix (".part")
            && !name.has_suffix (".crdownload")
            && !name.has_suffix (".download");
    }

    public void open_location () {
        var context = Gdk.Display.get_default ().get_app_launch_context ();
        try {
            AppInfo.launch_default_for_uri (File.new_for_path (config.source).get_uri (), context);
        } catch (Error e) {
            critical ("Failed to open %s: %s", config.source, e.message);
        }
    }

    /* The icon for the stack as a whole. */
    public Icon folder_icon () {
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

    private void on_monitor_changed (File file, File? other, FileMonitorEvent event) {
        queue_reload ();
    }

    private void queue_reload () {
        if (reload_id != 0) {
            Source.remove (reload_id);
        }

        reload_id = Timeout.add_once (RELOAD_DELAY_MS, () => {
            reload_id = 0;
            reload.begin ();
        });
    }

    private async void reload () {
        if (cancellable != null) {
            cancellable.cancel ();
        }
        var current = new Cancellable ();
        cancellable = current;

        GenericArray<StackEntry> loaded_entries;
        if (config.is_applications) {
            loaded_entries = load_applications ();
        } else {
            loaded_entries = yield load_folder (current);
        }

        if (current.is_cancelled ()) {
            return;
        }

        loaded_entries.sort (config.sort == NAME ? (CompareFunc<StackEntry>) compare_name : (CompareFunc<StackEntry>) compare_newest_first);

        Object[] items = {};
        Object[] previews = {};
        if (groups_folders) {
            var folders = new GenericArray<ListStore> ();
            for (int f = 0; f <= AppFolders.Folder.TERMINAL; f++) {
                folders.add (new ListStore (typeof (StackEntry)));
            }
            foreach (var entry in loaded_entries) {
                var folder = AppFolders.classify_app (entry.app);
                if (folder == NONE) {
                    items += entry;
                    previews += entry;
                } else {
                    folders[folder].append (entry);
                }
            }
            for (int f = AppFolders.Folder.GAMES; f <= AppFolders.Folder.TERMINAL; f++) {
                if (folders[f].get_n_items () > 0) {
                    items += StackEntry.for_folder (((AppFolders.Folder) f).title (), folders[f]);
                }
            }
        } else {
            foreach (var entry in loaded_entries) {
                items += entry;
                previews += entry;
            }
        }
        preview_store.splice (0, preview_store.get_n_items (), previews);
        store.splice (0, store.get_n_items (), items);

        loaded ();
    }

    private async GenericArray<StackEntry> load_folder (Cancellable cancellable) {
        var result = new GenericArray<StackEntry> ();
        var dir = File.new_for_path (config.source);

        try {
            var enumerator = yield dir.enumerate_children_async (FILE_ATTRIBUTES, NONE, Priority.DEFAULT, cancellable);
            missing = false;

            List<FileInfo> infos;
            while ((infos = yield enumerator.next_files_async (64, Priority.DEFAULT, cancellable)) != null) {
                foreach (var info in infos) {
                    if (info.get_is_hidden () || info.get_is_backup () || !is_shown_name (info.get_name ())) {
                        continue;
                    }
                    result.add (StackEntry.from_file_info (dir.get_child (info.get_name ()), info));
                }
            }
        } catch (IOError.CANCELLED e) {
            // A newer reload took over.
        } catch (IOError.NOT_FOUND e) {
            missing = true;
        } catch (Error e) {
            missing = true;
            warning ("Failed to read %s: %s", config.source, e.message);
        }

        return result;
    }

    private GenericArray<StackEntry> load_applications () {
        var result = new GenericArray<StackEntry> ();
        foreach (var app in AppInfo.get_all ()) {
            if (app.should_show ()) {
                result.add (StackEntry.from_app (app));
            }
        }
        return result;
    }

    private static int compare_name (StackEntry a, StackEntry b) {
        return a.name.casefold ().collate (b.name.casefold ());
    }

    private static int compare_newest_first (StackEntry a, StackEntry b) {
        if (a.added_usec != b.added_usec) {
            return a.added_usec > b.added_usec ? -1 : 1;
        }
        return compare_name (a, b);
    }
}
