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
    private bool torn_down = false;

    public StackItem (StackConfig config) {
        var source = new StackSource (config);
        Object (
            config: config,
            source: source,
            icons: new Gtk.MapListModel (source.entries, entry_icon),
            group: Group.NONE
        );
    }

    // A static method rather than a lambda: valac turns a lambda inside this chain-up
    // call into an instance closure over the not-yet-constructed `this` (NULL), and
    // the MapListModel then calls g_object_unref (NULL) on it when it is finalized.
    private static Object entry_icon (owned Object entry) {
        Object icon = ((StackEntry) entry).icon;
        return icon;
    }

    construct {
        StackStyle.ensure ();
        add_css_class ("stack");

        // BaseIconGroup has already set child to its icon grid.
        preview = child;

        folder_image = new Gtk.Image.from_gicon (source.folder_icon ());
        bind_property ("icon-size", folder_image, "pixel-size", SYNC_CREATE);

        tooltip_text = config.is_applications ? _("Applications") : Path.get_basename (config.source);

        popover_menu = create_popover ();
        popover_menu.set_parent (this);

        // Methods, not lambdas: a lambda that uses `this` holds a strong ref to it,
        // and gesture_click and our own parent signal are owned by this item.
        gesture_click.released.connect (on_released);

        source.notify["missing"].connect (update_child);
        source.entries.items_changed.connect (update_child);
        update_child ();

        // ItemGroup.finish_remove () only unparents a removed item, and upstream
        // BaseItem.cleanup () is never called, so nothing else tells us we are gone.
        // notify::parent is emitted for exactly that unparent (it is not emitted
        // while the parent stays null), whereas unroot would also fire when the
        // whole dock window is torn down.
        // Teardown is final. ItemGroup could re-add a removed item that is still in
        // its one-idle cache, but only for the same model object, and StackStore
        // splices fresh StackConfig objects on every change, so that cannot happen here.
        notify["parent"].connect (on_parent_changed);

        maybe_open_for_test ();
    }

    ~StackItem () {
        debug ("StackItem finalized for %s", config.source);
    }

    // Test hook for screenshot checks: with DOCK_STACKS_OPEN=<index into `stacks`>,
    // that stack pops its popover up once, 1.5 s after the dock starts.
    private void maybe_open_for_test () {
        var wanted = Environment.get_variable ("DOCK_STACKS_OPEN");
        if (wanted == null) {
            return;
        }
        var configs = StackConfig.parse_all (new Settings ("io.elementary.dock").get_value ("stacks"));
        var index = int.parse (wanted);
        if (index >= 0 && index < configs.length && configs[index].source == config.source) {
            Timeout.add_once (1500, open_for_test);
        }
    }

    private void open_for_test () {
        if (!torn_down) {
            popover_menu.popup ();
        }
    }

    private void on_released () {
        popover_menu.popup ();
    }

    private void on_parent_changed () {
        if (parent == null) {
            teardown ();
        }
    }

    private void teardown () {
        if (torn_down) {
            return;
        }
        torn_down = true;
        debug ("StackItem teardown for %s", config.source);

        // BaseIconGroup's FlowBox owns its create_flow_box_child delegate, which holds
        // a ref to this item (item -> overlay -> FlowBox -> item), and `preview` keeps
        // the FlowBox alive even while it is not our child.
        ((Gtk.FlowBox) preview).bind_model (null, null);

        source.notify["missing"].disconnect (update_child);
        source.entries.items_changed.disconnect (update_child);
        source.stop ();

        popover_menu.unparent ();

        // Upstream's own hook for dropping the animation callbacks that capture this item.
        cleanup ();
    }

    private Gtk.Popover create_popover () {
        switch (config.view) {
            case FAN: return new FanPopover (source);
            default: return new GridPopover (source);
        }
    }

    private void update_child () {
        var empty = source.missing || source.entries.get_n_items () == 0;
        Gtk.Widget wanted = (config.display == FOLDER || empty) ? folder_image : preview;
        if (child != wanted) {
            child = wanted;
        }
        folder_image.opacity = source.missing ? 0.5 : 1.0;
    }
}
