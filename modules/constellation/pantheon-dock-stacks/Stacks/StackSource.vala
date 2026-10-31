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

    public StackConfig config { get; construct; }
    public ListModel entries { get { return store; } }
    public bool missing { get; private set; default = false; }

    private ListStore store;
    private FileMonitor? monitor;
    private AppInfoMonitor? app_monitor;
    private Cancellable? cancellable;
    private uint reload_id = 0;

    public StackSource (StackConfig config) {
        Object (config: config);
    }

    construct {
        store = new ListStore (typeof (StackEntry));

        if (config.is_applications) {
            app_monitor = AppInfoMonitor.get ();
            app_monitor.changed.connect (queue_reload);
        } else {
            try {
                monitor = File.new_for_path (config.source).monitor_directory (WATCH_MOVES, null);
                monitor.changed.connect ((file, other, event) => queue_reload ());
            } catch (Error e) {
                debug ("Not watching %s: %s", config.source, e.message);
            }
        }

        // Deferred so callers can connect to `loaded` before the first load.
        queue_reload ();
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
        foreach (var entry in loaded_entries) {
            items += entry;
        }
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
