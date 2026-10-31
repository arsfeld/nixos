/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Unity LauncherEntry progress, for the Downloads tile. Chromium browsers
 * (Chrome, Brave, Vivaldi) report download progress this way; Firefox and Zen
 * report it nowhere, so their downloads only pulse. Upstream AppSystem listens
 * to the same signal for its launchers; this subscription is independent.
 */

public class Dock.LauncherProgress : Object {
    private class State {
        public double progress = 0;
        public bool visible = false;
    }

    private static LauncherProgress? instance;
    public static unowned LauncherProgress get_default () {
        if (instance == null) {
            instance = new LauncherProgress ();
        }
        return instance;
    }

    public signal void changed ();

    private HashTable<string, State> states = new HashTable<string, State> (str_hash, str_equal);
    private bool started = false;

    /* Subscribes on the session bus. Idempotent; the unit tests never call it. */
    public void start () {
        if (started) {
            return;
        }
        started = true;
        Bus.get.begin (BusType.SESSION, null, on_bus);
    }

    private void on_bus (Object? obj, AsyncResult res) {
        try {
            var connection = Bus.get.end (res);
            connection.signal_subscribe (
                null, "com.canonical.Unity.LauncherEntry", "Update", null, null,
                DBusSignalFlags.NONE, on_signal
            );
        } catch (Error e) {
            warning ("No session bus for LauncherEntry progress: %s", e.message);
        }
    }

    private void on_signal (DBusConnection connection, string? sender, string path, string iface,
                            string signal_name, Variant parameters) {
        handle_update (parameters);
    }

    /* parameters: (sa{sv}), an application:// URI and the changed properties. */
    public void handle_update (Variant parameters) {
        if (!parameters.is_of_type (new VariantType ("(sa{sv})"))) {
            return;
        }
        string uri;
        VariantIter props;
        parameters.get ("(sa{sv})", out uri, out props);

        double? progress = null;
        bool? visible = null;
        string key;
        Variant value;
        while (props.next ("{sv}", out key, out value)) {
            if (key == "progress" && value.is_of_type (VariantType.DOUBLE)) {
                progress = value.get_double ();
            } else if (key == "progress-visible" && value.is_of_type (VariantType.BOOLEAN)) {
                visible = value.get_boolean ();
            }
        }
        update (uri.replace ("application://", ""), progress, visible);
    }

    /* A null argument leaves that property as it was: updates are partial. */
    public void update (string app_id, double? progress, bool? visible) {
        if (progress == null && visible == null) {
            return;
        }
        var state = states[app_id];
        if (state == null) {
            state = new State ();
            states[app_id] = state;
        }
        if (progress != null) {
            state.progress = progress;
        }
        if (visible != null) {
            state.visible = visible;
        }
        changed ();
    }

    /* The mean progress of every browser showing progress, or -1 if none is. */
    public double download_fraction () {
        double sum = 0;
        uint count = 0;
        states.foreach ((app_id, state) => {
            if (state.visible && is_browser (app_id)) {
                sum += state.progress;
                count++;
            }
        });
        return count == 0 ? -1 : sum / count;
    }

    public static bool is_browser (string app_id) {
        var info = new DesktopAppInfo (app_id);
        if (info == null) {
            return false;
        }
        return "x-scheme-handler/https" in (info.get_string ("MimeType") ?? "").split (";");
    }
}
