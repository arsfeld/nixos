/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The io.elementary.dock `stacks` key as a list model of StackConfig.
 */

public class Dock.StackStore : Object {
    public ListModel configs { get { return store; } }

    private Settings settings;
    private ListStore store;

    construct {
        store = new ListStore (typeof (StackConfig));
        settings = new Settings ("io.elementary.dock");
        if (settings.settings_schema.has_key ("stacks")) {
            settings.changed["stacks"].connect (load);
        }
        load ();
    }

    // The `stacks` key exists only in a schema built from our patch. A dock started in a
    // session that still points at an older schema directory (until the user logs back in
    // after a deploy) would abort inside GLib on get_value, so check first.
    public static Variant? read_stacks (Settings settings) {
        if (!settings.settings_schema.has_key ("stacks")) {
            warning ("The io.elementary.dock schema has no 'stacks' key (stale session schema?); showing no stacks");
            return null;
        }
        return settings.get_value ("stacks");
    }

    private void load () {
        Object[] items = {};
        var value = read_stacks (settings);
        if (value != null) {
            foreach (var config in StackConfig.parse_all (value)) {
                items += config;
            }
        }
        store.splice (0, store.get_n_items (), items);
    }
}
