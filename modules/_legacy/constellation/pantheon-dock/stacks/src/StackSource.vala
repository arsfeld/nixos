/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The live, sorted contents of one stack: a folder watched with a
 * FileMonitor, or every app that should be shown.
 */

public class Dock.StackSource : Object {
    private const string FILE_ATTRIBUTES = "standard::name,standard::display-name,standard::icon," +
        "standard::is-hidden,standard::is-backup,standard::size,time::created,time::created-usec," +
        "time::modified,time::modified-usec,thumbnail::path";
    // Downloads arrive as bursts of events (create, write, rename); reload once per burst.
    private const uint RELOAD_DELAY_MS = 200;
    private const string[] DOWNLOAD_SUFFIXES = { ".part", ".crdownload", ".download" };
    private const string REFRESH_ATTRIBUTES = "standard::size,time::modified,time::modified-usec";

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
    /* The tile shows a progress bar while this is true. */
    public bool tile_busy { get; private set; default = false; }
    /* 0–1, or below 0 to pulse. */
    public double tile_progress { get; private set; default = -1; }

    private ListStore store;
    private ListStore preview_store;
    private FileMonitor? monitor;
    private AppInfoMonitor? app_monitor;
    private Cancellable? cancellable;
    private uint reload_id = 0;
    private uint refresh_id = 0;
    // Every app entry (and provisional one) by desktop id, for job updates.
    private HashTable<string, StackEntry> by_desktop_id = new HashTable<string, StackEntry> (str_hash, str_equal);

    public StackSource (StackConfig config) {
        Object (config: config);
    }

    construct {
        store = new ListStore (typeof (StackEntry));
        preview_store = new ListStore (typeof (StackEntry));

        if (config.is_applications) {
            app_monitor = AppInfoMonitor.get ();
            app_monitor.changed.connect (queue_reload);
            AppCenterJobs.get_default ().changed.connect (on_job_changed);
        } else {
            try {
                monitor = File.new_for_path (config.source).monitor_directory (WATCH_MOVES, null);
                monitor.changed.connect (on_monitor_changed);
            } catch (Error e) {
                debug ("Not watching %s: %s", config.source, e.message);
            }
            LauncherProgress.get_default ().changed.connect (update_tile);
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
        LauncherProgress.get_default ().changed.disconnect (update_tile);
        AppCenterJobs.get_default ().changed.disconnect (on_job_changed);
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
        if (refresh_id != 0) {
            Source.remove (refresh_id);
            refresh_id = 0;
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
        return !name.has_prefix (".");
    }

    /* The in-progress download suffix of name, or null for a finished file. */
    public static string? download_suffix (string name) {
        foreach (unowned var suffix in DOWNLOAD_SUFFIXES) {
            if (name.has_suffix (suffix)) {
                return suffix;
            }
        }
        return null;
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
        // A download writes its partial file many times a second; refresh_downloads
        // follows its size, so only its creation, rename and deletion reload.
        var content_only = event == CHANGED || event == CHANGES_DONE_HINT || event == ATTRIBUTE_CHANGED;
        if (content_only && download_suffix (file.get_basename ()) != null) {
            return;
        }
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

        by_desktop_id.remove_all ();
        Object[] provisional = {};
        if (config.is_applications) {
            foreach (var entry in loaded_entries) {
                by_desktop_id[entry.app.get_id ()] = entry;
            }
            foreach (var job in AppCenterJobs.get_default ().get_all ()) {
                if (job.state == INSTALLING && job.desktop_id != "" && !(job.desktop_id in by_desktop_id)) {
                    var entry = StackEntry.provisional (job);
                    by_desktop_id[job.desktop_id] = entry;
                    provisional += entry;
                }
            }
            by_desktop_id.foreach ((desktop_id, entry) => {
                apply_job (entry, AppCenterJobs.get_default ().for_desktop_id (desktop_id));
            });
        }

        Object[] items = provisional;
        Object[] previews = provisional;
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
        update_folder_progress ();

        update_tile ();
        update_refresh ();
        loaded ();
    }

    private bool has_downloads () {
        for (uint i = 0; i < store.get_n_items (); i++) {
            if (((StackEntry) store.get_item (i)).downloading) {
                return true;
            }
        }
        return false;
    }

    /* Runs refresh_downloads once a second while there is anything to refresh. */
    private void update_refresh () {
        if (has_downloads () && refresh_id == 0) {
            refresh_id = arm_refresh (this);
        } else if (!has_downloads () && refresh_id != 0) {
            Source.remove (refresh_id);
            refresh_id = 0;
        }
    }

    /*
     * Static on purpose: a lambda in an instance method captures `this` strongly,
     * and a repeating timer would then keep an unreferenced source alive. The
     * timer holds the source only weakly.
     */
    private static uint arm_refresh (StackSource source) {
        var weak_self = WeakRef (source);
        return Timeout.add_seconds (1, () => {
            var current = weak_self.get () as StackSource;
            return current != null ? current.on_refresh_tick () : Source.REMOVE;
        });
    }

    private bool on_refresh_tick () {
        refresh_downloads.begin ();
        return Source.CONTINUE;
    }

    private async void refresh_downloads () {
        var now = get_real_time ();
        for (uint i = 0; i < store.get_n_items (); i++) {
            var entry = (StackEntry) store.get_item (i);
            if (!entry.downloading) {
                continue;
            }
            try {
                var info = yield entry.file.query_info_async (REFRESH_ATTRIBUTES, NONE, Priority.DEFAULT, cancellable);
                var modified = (int64) info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED) * 1000000
                    + info.get_attribute_uint32 (FileAttribute.TIME_MODIFIED_USEC);
                entry.update_download (info.get_size (), modified, now);
            } catch (Error e) {
                // Renamed on completion or cancelled: the next reload handles it.
            }
        }
        update_tile ();
    }

    private void update_tile () {
        if (config.is_applications) {
            var jobs = AppCenterJobs.get_default ();
            set_tile (jobs.count > 0, jobs.mean_progress ());
            return;
        }

        bool busy = false;
        bool chromium = false;
        for (uint i = 0; i < store.get_n_items (); i++) {
            var entry = (StackEntry) store.get_item (i);
            if (entry.downloading && !entry.stalled) {
                busy = true;
                chromium = chromium || entry.file.get_basename ().has_suffix (".crdownload");
            }
        }
        set_tile (busy, chromium ? LauncherProgress.get_default ().download_fraction () : -1);
    }

    private static void apply_job (StackEntry entry, AppCenterJobs.Job? job) {
        if (job == null || job.state == IDLE) {
            entry.job_component_id = null;
            entry.status_text = null;
            entry.show_progress = false;
            return;
        }
        entry.job_component_id = job.component_id;
        entry.status_text = job.status_text ();
        entry.progress = job.progress;
        entry.show_progress = true;
    }

    /* A folder shows a bar while any of its apps is busy: their mean progress. */
    private void update_folder_progress () {
        for (uint i = 0; i < store.get_n_items (); i++) {
            var folder = (StackEntry) store.get_item (i);
            if (!folder.is_folder) {
                continue;
            }
            double sum = 0;
            uint busy = 0;
            for (uint j = 0; j < folder.children.get_n_items (); j++) {
                var child = (StackEntry) folder.children.get_item (j);
                if (child.show_progress) {
                    sum += child.progress;
                    busy++;
                }
            }
            folder.show_progress = busy > 0;
            folder.progress = busy > 0 ? sum / busy : -1;
        }
    }

    private void on_job_changed (AppCenterJobs.Job job) {
        var entry = job.desktop_id != "" ? by_desktop_id[job.desktop_id] : null;
        var is_provisional = entry != null && entry.app == null;
        if (entry == null && job.state == INSTALLING && job.desktop_id != "") {
            // A new install: the reload adds its provisional cell.
            queue_reload ();
        } else if (is_provisional && job.state == IDLE) {
            // Done: the reload drops the provisional cell. AppInfoMonitor also
            // reloads once the real desktop file appears.
            queue_reload ();
        } else if (entry != null) {
            apply_job (entry, job);
            update_folder_progress ();
        }
        update_tile ();
    }

    // Only on change: the tile bar is re-laid-out on every notify.
    private void set_tile (bool busy, double progress) {
        if (tile_busy != busy) {
            tile_busy = busy;
        }
        // An idle tile keeps its last value, so the bar does not start pulsing while it fades out.
        if (busy && tile_progress != progress) {
            tile_progress = progress;
        }
    }

    private async GenericArray<StackEntry> load_folder (Cancellable cancellable) {
        var result = new GenericArray<StackEntry> ();
        var dir = File.new_for_path (config.source);

        try {
            var enumerator = yield dir.enumerate_children_async (FILE_ATTRIBUTES, NONE, Priority.DEFAULT, cancellable);
            missing = false;

            var infos = new GenericArray<FileInfo> ();
            var names = new GenericSet<string> (str_hash, str_equal);
            List<FileInfo> batch;
            while ((batch = yield enumerator.next_files_async (64, Priority.DEFAULT, cancellable)) != null) {
                foreach (var info in batch) {
                    infos.add (info);
                    names.add (info.get_name ());
                }
            }

            foreach (var info in infos) {
                var name = info.get_name ();
                if (info.get_is_hidden () || info.get_is_backup () || !is_shown_name (name)) {
                    continue;
                }
                // Firefox creates the final name empty next to name.part while it downloads.
                if (info.get_size () == 0 && names.contains (name + ".part")) {
                    continue;
                }
                result.add (StackEntry.from_file_info (dir.get_child (name), info));
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
