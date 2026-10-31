/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * A folder stack on the dock: a pile of the newest entries, a 2×2 preview, or a
 * plain folder icon, opening as a fan or a grid.
 */

public class Dock.StackItem : BaseIconGroup {
    public StackConfig config { get; construct; }
    public StackSource source { get; construct; }

    private Gtk.Widget preview;
    private Gtk.Image folder_image;
    private StackPile pile;
    private bool torn_down = false;

    // The launch bounce. Launcher.animate_launch plays the same one, but its
    // animations are private to Launcher, so this is a copy rather than a share.
    private Adw.TimedAnimation? bounce_up;
    private Adw.TimedAnimation? bounce_down;

    public StackItem (StackConfig config) {
        var source = new StackSource (config);
        Object (
            config: config,
            source: source,
            icons: new Gtk.MapListModel (source.previews, entry_icon),
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

        pile = new StackPile (source);
        bind_property ("icon-size", pile, "icon-size", SYNC_CREATE);

        tooltip_text = config.is_applications ? _("Applications") : Path.get_basename (config.source);

        popover_menu = create_popover ();
        popover_menu.set_parent (this);

        // Methods, not lambdas: a lambda that uses `this` holds a strong ref to it,
        // and gesture_click and our own parent signal are owned by this item.
        gesture_click.released.connect (on_released);

        var bounce_target = new Adw.CallbackAnimationTarget (bounce_frame);
        bounce_down = new Adw.TimedAnimation (this, 0, 0, 600, bounce_target) {
            easing = EASE_OUT_BOUNCE
        };
        bounce_up = new Adw.TimedAnimation (this, 0, 0, 200, bounce_target) {
            easing = EASE_IN_OUT_QUAD
        };
        bounce_up.done.connect (on_bounce_up_done);
        source.launched.connect (animate_launch);

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
    // that stack pops its popover up 1.5 s after each matching StackItem is built (so again whenever `stacks` changes).
    // With DOCK_STACKS_FOLDER=<folder name> too, an Applications grid opens that folder.
    private void maybe_open_for_test () {
        var wanted = Environment.get_variable ("DOCK_STACKS_OPEN");
        if (wanted == null) {
            return;
        }
        var value = StackStore.read_stacks (new Settings ("io.elementary.dock"));
        if (value == null) {
            return;
        }
        var configs = StackConfig.parse_all (value);
        var index = int.parse (wanted);
        if (index >= 0 && index < configs.length && configs[index].source == config.source) {
            Timeout.add_once (1500, open_for_test);
        }
    }

    private void open_for_test () {
        if (torn_down) {
            return;
        }
        popover_menu.popup ();
        var folder = Environment.get_variable ("DOCK_STACKS_FOLDER");
        if (folder != null && popover_menu is GridPopover) {
            ((GridPopover) popover_menu).open_folder_for_test (folder);
        }
        if (Environment.get_variable ("DOCK_STACKS_CLICK") != null) {
            Timeout.add_once (700, click_for_test);
        }
    }

    // Test hook: DOCK_STACKS_CLICK=<row>[@<progress>], with DOCK_STACKS_OPEN, plays
    // that fan row's launch (row 0 is the newest entry, the last row "Open in
    // Files") and the tile's bounce, without opening anything. With a progress
    // (0–1) the fan holds at that point instead, for a screenshot.
    private void click_for_test () {
        if (torn_down || !(popover_menu is FanPopover)) {
            return;
        }
        var parts = Environment.get_variable ("DOCK_STACKS_CLICK").split ("@", 2);
        var progress = parts.length > 1 ? double.parse (parts[1]) : -1;
        ((FanPopover) popover_menu).launch_for_test ((uint) int.parse (parts[0]), progress);
    }

    private void on_released () {
        popover_menu.popup ();
    }

    private void bounce_frame (double value) {
        overlay.allocate (
            overlay.get_width (), overlay.get_height (), -1,
            new Gsk.Transform ().translate ({ 0, (int) value })
        );
    }

    // A method, not a connection to bounce_down.play: teardown () may drop
    // bounce_down while bounce_up is still playing.
    private void on_bounce_up_done () {
        if (bounce_down != null) {
            bounce_down.play ();
        }
    }

    private void animate_launch () {
        if (bounce_up == null || bounce_up.state == PLAYING || bounce_down.state == PLAYING) {
            return;
        }
        bounce_up.value_to = -0.5 * overlay.get_height ();
        bounce_down.value_from = bounce_up.value_to;
        bounce_up.play ();
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
        pile.stop ();
        source.launched.disconnect (animate_launch);
        // The bounce target's callback holds this item; Launcher drops its
        // animations in cleanup () for the same reason.
        bounce_up = null;
        bounce_down = null;
        source.stop ();

        // popdown () first: unparent () alone never emits closed, and the zoom's
        // ItemManager.frozen_popover holds an open popover until it does.
        popover_menu.popdown ();
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
        Gtk.Widget wanted;
        if (empty || config.display == FOLDER) {
            wanted = folder_image;
        } else if (config.display == GRID) {
            wanted = preview;
        } else {
            wanted = pile;
        }
        if (child != wanted) {
            child = wanted;
        }
        folder_image.opacity = source.missing ? 0.5 : 1.0;
    }
}
