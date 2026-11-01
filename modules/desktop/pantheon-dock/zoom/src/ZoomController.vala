/*
 * SPDX-License-Identifier: GPL-3.0
 */

/**
 * Owns the dock's zoom: where the pointer is in resting coordinates, how far
 * the zoom has eased in, and the clamped peak factor from settings.
 */
public class Dock.ZoomController : Object {
    private const uint EASE_DURATION = 150;

    public signal void changed ();

    public Gtk.Widget widget { get; construct; }

    /** 0 at rest, 1 fully zoomed. */
    public double amount { get; private set; default = 0.0; }

    /** How far magnified icons rise above the dock while zoomed, for the input region. */
    public int input_rise {
        get { return amount > 0.0 ? max_rise : 0; }
    }

    private GLib.Settings? settings;
    private Adw.TimedAnimation ease;
    private bool enabled = false;
    private double max_factor = 1.0;
    private int max_rise = 0;
    private double pointer_rest_x = 0.0;

    public ZoomController (Gtk.Widget widget) {
        Object (widget: widget);
    }

    construct {
        settings = new GLib.Settings ("io.elementary.dock");
        // The zoom keys exist only in a schema built from our patch. A dock restarted in a
        // session that still points at an older schema directory (until the user logs back
        // in after a deploy) would abort inside GLib on get_*, so check first and stay at rest.
        if (!settings.settings_schema.has_key ("zoom-enabled") || !settings.settings_schema.has_key ("zoom-size")) {
            warning ("The io.elementary.dock schema has no zoom keys (stale session schema?); zoom is off");
            settings = null;
        }

        ease = new Adw.TimedAnimation (
            widget, 0, 1, EASE_DURATION,
            new Adw.CallbackAnimationTarget (on_ease)
        ) {
            easing = EASE_OUT_QUAD
        };

        if (settings != null) {
            settings.changed["zoom-enabled"].connect (update_settings);
            settings.changed["zoom-size"].connect (update_settings);
            settings.changed["icon-size"].connect (update_settings);
            update_settings ();
        }
    }

    private void on_ease (double val) {
        amount = val;
        changed ();
    }

    private void update_settings () {
        enabled = settings.get_boolean ("zoom-enabled");

        var icon_size = settings.get_int ("icon-size");
        var item_height = icon_size + Launcher.PADDING;
        var max_size = ZoomMath.max_zoom_size (icon_size, item_height, MainWindow.TOP_MARGIN);
        var size = settings.get_int ("zoom-size");
        var clamped = size.clamp (icon_size, max_size);
        if (clamped != size) {
            warning ("zoom-size %d is outside %d…%d; using %d", size, icon_size, max_size, clamped);
        }

        max_factor = (double) clamped / icon_size;
        max_rise = (int) Math.ceil (ZoomMath.rise (item_height, max_factor));

        if (!enabled) {
            ease_to (0.0);
        }

        changed ();
    }

    public void pointer_moved (double rest_x) {
        pointer_rest_x = rest_x;
        if (enabled) {
            ease_to (1.0);
        }

        changed ();
    }

    public void pointer_left () {
        ease_to (0.0);
    }

    /** The zoom for an item whose resting centre is at rest_center. */
    public double factor_at (double rest_center) {
        if (amount <= 0.0) {
            return 1.0;
        }

        var peak = ZoomMath.factor (rest_center - pointer_rest_x, ItemManager.get_launcher_size (), max_factor);
        return 1.0 + (peak - 1.0) * amount;
    }

    private void ease_to (double target) {
        var playing = ease.state == Adw.AnimationState.PLAYING;
        if (ease.value_to == target && (playing || amount == target)) {
            return;
        }

        // reset () snaps amount back to the old value_from, so remember where we are.
        var from = amount;
        ease.reset ();
        ease.value_from = from;
        ease.value_to = target;
        ease.play ();
    }
}
