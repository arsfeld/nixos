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
        settings.changed["stacks"].connect (load);
        load ();
    }

    private void load () {
        Object[] items = {};
        foreach (var config in StackConfig.parse_all (settings.get_value ("stacks"))) {
            items += config;
        }
        store.splice (0, store.get_n_items (), items);
    }
}
