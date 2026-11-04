/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Gives a Gtk.Image a bitmap sized for what it finally covers on screen.
 * Gtk.Image picks its bitmap from the widget's scale factor alone, so an icon
 * that a transform later magnifies (the zoom) or that is painted into a
 * supersampled texture (StackRender) is a stretched 1× bitmap. This looks the
 * icon up at render_scale × oversample × the scale factor and hands the image
 * the paintable, while pixel_size stays the logical size: layout and icon CSS
 * (-gtk-icon-shadow, symbolic recolouring) are unchanged.
 */
public class Dock.IconResolution : Object {
    private const string KEY = "dock-icon-resolution";

    public Icon? icon { get; set; }
    public int render_scale { get; set; default = 1; }

    // Unowned: the image owns this helper (set_data in attach), not the reverse.
    private unowned Gtk.Image image;
    private int oversample;

    private IconResolution (Gtk.Image image, int oversample) {
        this.image = image;
        this.oversample = oversample;

        // Methods, not lambdas: valac connects them with g_signal_connect_object,
        // so they go away with this helper and hold no reference to it.
        notify["icon"].connect (update);
        notify["render-scale"].connect (update);
        image.notify["pixel-size"].connect (update);
        image.notify["scale-factor"].connect (update);
        Gtk.IconTheme.get_for_display (image.get_display ()).changed.connect (update);
    }

    /* Takes over image's icon. Set icon on the returned helper, never gicon on the image. */
    public static IconResolution attach (Gtk.Image image, Icon? icon, int oversample = 1) {
        var resolution = new IconResolution (image, oversample);
        image.set_data<IconResolution> (KEY, resolution);
        resolution.icon = icon;
        return resolution;
    }

    private void update () {
        if (icon == null) {
            image.paintable = null;
            return;
        }
        // No logical size yet: let GTK size it, and look up again once pixel_size is set.
        if (image.pixel_size <= 0) {
            image.gicon = icon;
            return;
        }
        var scale = IconMath.lookup_scale (image.get_scale_factor (), oversample, render_scale);
        // Not the Gtk.IconPaintable itself: gtk_icon_helper_load_paintable () (gtk/gtkiconhelper.c)
        // resets the "scale" of a bare Gtk.IconPaintable to the widget's scale factor, which
        // discards the lookup scale above. A wrapper is not one, so the bitmap survives.
        image.paintable = new SharpPaintable (Gtk.IconTheme.get_for_display (image.get_display ())
            .lookup_by_gicon (icon, image.pixel_size, scale, image.get_direction (), 0));
    }
}

/* Hands every call to a Gtk.IconPaintable, so Gtk.Image treats it as an opaque paintable. */
private class Dock.SharpPaintable : Object, Gdk.Paintable, Gtk.SymbolicPaintable {
    private Gtk.IconPaintable inner;

    public SharpPaintable (Gtk.IconPaintable inner) {
        this.inner = inner;
    }

    public void snapshot (Gdk.Snapshot snapshot, double width, double height) {
        inner.snapshot (snapshot, width, height);
    }

    public void snapshot_symbolic (Gdk.Snapshot snapshot, double width, double height, Gdk.RGBA[] colors) {
        inner.snapshot_symbolic (snapshot, width, height, colors);
    }

    public void snapshot_with_weight (Gdk.Snapshot snapshot, double width, double height, Gdk.RGBA[] colors, double weight) {
        inner.snapshot_with_weight (snapshot, width, height, colors, weight);
    }

    public int get_intrinsic_width () {
        return inner.get_intrinsic_width ();
    }

    public int get_intrinsic_height () {
        return inner.get_intrinsic_height ();
    }

    public Gdk.PaintableFlags get_flags () {
        return Gdk.PaintableFlags.STATIC_SIZE | Gdk.PaintableFlags.STATIC_CONTENTS;
    }
}
