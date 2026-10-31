/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The thin progress bar of a stack tile, fan row or grid cell, styled like
 * upstream Launcher's Unity bar. A fraction below 0 pulses it.
 */

public class Dock.StackProgressBar : Gtk.Widget {
    private const int64 PULSE_USEC = 120000;

    /* 0–1, or below 0 for indeterminate. */
    public double fraction { get; set; default = -1; }

    private Gtk.ProgressBar bar;
    private uint tick_id = 0;
    private int64 last_pulse = 0;

    class construct {
        set_layout_manager_type (typeof (Gtk.BinLayout));
    }

    construct {
        bar = new Gtk.ProgressBar () {
            pulse_step = 0.15
        };
        bar.add_css_class ("stack-progress");
        bar.set_parent (this);
        notify["fraction"].connect (update_fraction);
        update_fraction ();
    }

    public override void dispose () {
        if (bar != null) {
            bar.unparent ();
            bar = null;
        }
        base.dispose ();
    }

    // Tick only while on screen and indeterminate: the tick callback holds this
    // widget, and is dropped in unmap, which GTK always runs before the widget
    // goes away.
    public override void map () {
        base.map ();
        update_tick ();
    }

    public override void unmap () {
        remove_tick ();
        base.unmap ();
    }

    private void update_tick () {
        if (get_mapped () && fraction < 0) {
            if (tick_id == 0) {
                tick_id = add_tick_callback (on_tick);
            }
        } else {
            remove_tick ();
        }
    }

    private void remove_tick () {
        if (tick_id != 0) {
            remove_tick_callback (tick_id);
            tick_id = 0;
        }
    }

    private bool on_tick (Gtk.Widget widget, Gdk.FrameClock clock) {
        if (fraction < 0) {
            var now = clock.get_frame_time ();
            if (now - last_pulse >= PULSE_USEC) {
                bar.pulse ();
                last_pulse = now;
            }
        }
        return Source.CONTINUE;
    }

    private void update_fraction () {
        if (fraction >= 0) {
            bar.fraction = fraction.clamp (0, 1);
        }
        update_tick ();
    }
}

namespace Dock.StackBusy {
    /*
     * Shows entry's busy state on a cell's widgets: dims icon, fills status,
     * and reveals the bar. The bindings are added to `bindings` so a recycled
     * grid cell can unbind them; a fan row just lets them die with it.
     */
    public void bind (StackEntry entry, Gtk.Widget icon, Gtk.Label status, Gtk.Revealer bar_revealer,
                      StackProgressBar bar, GenericArray<Binding> bindings) {
        bindings.add (entry.bind_property ("status-text", icon, "opacity", SYNC_CREATE, busy_to_opacity));
        bindings.add (entry.bind_property ("status-text", status, "label", SYNC_CREATE, null_to_empty));
        bindings.add (entry.bind_property ("status-text", status, "visible", SYNC_CREATE, is_busy));
        bindings.add (entry.bind_property ("show-progress", bar_revealer, "reveal-child", SYNC_CREATE));
        bindings.add (entry.bind_property ("progress", bar, "fraction", SYNC_CREATE));
    }

    public bool is_busy (Binding binding, Value from, ref Value to) {
        to.set_boolean (from.get_string () != null);
        return true;
    }

    private bool busy_to_opacity (Binding binding, Value from, ref Value to) {
        to.set_double (from.get_string () != null ? 0.5 : 1.0);
        return true;
    }

    private bool null_to_empty (Binding binding, Value from, ref Value to) {
        to.set_string (from.get_string () ?? "");
        return true;
    }

    /* A crossfading revealer around a new bar, aligned to the bottom of an icon. */
    public Gtk.Revealer new_bar_revealer (out StackProgressBar bar) {
        bar = new StackProgressBar ();
        return new Gtk.Revealer () {
            child = bar,
            can_target = false,
            transition_type = CROSSFADE,
            valign = END
        };
    }
}
