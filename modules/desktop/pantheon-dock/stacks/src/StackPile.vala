/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The dock tile of a `display = stack` stack: the newest entry's icon in front
 * and the next two peeking out behind it, tilted apart like a pile of papers,
 * as macOS draws "Display as Stack".
 */

public class Dock.StackPile : Gtk.Widget {
    // Per slot, front first: icon size and centre offset as fractions of the
    // tile (y grows downwards), and clockwise tilt in degrees. Tuned on screen.
    private const double[] SIZES = { 0.86, 0.76, 0.76 };
    private const double[] OFFSETS_X = { 0, -0.11, 0.12 };
    private const double[] OFFSETS_Y = { 0.07, -0.10, -0.12 };
    private const double[] DEGREES = { 0, -9, 8 };

    public StackSource source { get; construct; }
    public int icon_size { get; set; default = 48; }
    /** The owning item's BaseItem.render_scale. */
    public int render_scale { get; set; default = 1; }

    private GenericArray<Gtk.Image> images = new GenericArray<Gtk.Image> ();
    private GenericArray<IconResolution> resolutions = new GenericArray<IconResolution> ();
    private GenericArray<Gsk.Transform> transforms = new GenericArray<Gsk.Transform> ();

    public StackPile (StackSource source) {
        Object (source: source);
    }

    construct {
        overflow = VISIBLE;
        halign = CENTER;
        valign = CENTER;

        for (int k = 0; k < SIZES.length; k++) {
            var image = new Gtk.Image ();
            image.set_parent (this);
            images.add (image);
            // Tilted slots are painted through StackRender's supersampled texture.
            resolutions.add (IconResolution.attach (image, null, DEGREES[k] == 0 ? 1 : StackRender.OVERSAMPLE));
        }

        // Methods, not lambdas: a closure over `this` held by the source would
        // keep the pile alive for as long as the source is.
        notify["icon-size"].connect (update_sizes);
        notify["render-scale"].connect (update_render_scale);
        source.previews.items_changed.connect (update_icons);
        update_sizes ();
        update_icons ();
    }

    /* Called by StackItem.teardown (): stop following the source. */
    public void stop () {
        source.previews.items_changed.disconnect (update_icons);
    }

    public override void dispose () {
        foreach (var image in images) {
            image.unparent ();
        }
        resolutions.length = 0;
        images.length = 0;
        base.dispose ();
    }

    private int slot_size (int k) {
        return (int) Math.round (SIZES[k] * icon_size);
    }

    private void update_sizes () {
        for (int k = 0; k < images.length; k++) {
            images[k].pixel_size = slot_size (k);
        }
        queue_resize ();
    }

    private void update_render_scale () {
        foreach (var resolution in resolutions) {
            resolution.render_scale = render_scale;
        }
        queue_draw ();
    }

    private void update_icons () {
        var n = source.previews.get_n_items ();
        for (int k = 0; k < images.length; k++) {
            if (k < n) {
                resolutions[k].icon = ((StackEntry) source.previews.get_item (k)).icon;
                images[k].visible = true;
            } else {
                images[k].visible = false;
            }
        }
    }

    public override Gtk.SizeRequestMode get_request_mode () {
        return CONSTANT_SIZE;
    }

    public override void measure (Gtk.Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
        minimum = natural = icon_size;
        minimum_baseline = natural_baseline = -1;
    }

    public override void size_allocate (int width, int height, int baseline) {
        transforms = new GenericArray<Gsk.Transform> ();
        for (int k = 0; k < images.length; k++) {
            var size = slot_size (k);
            var transform = new Gsk.Transform ()
                .translate ({ (float) (width / 2.0 + OFFSETS_X[k] * icon_size), (float) (height / 2.0 + OFFSETS_Y[k] * icon_size) })
                .rotate ((float) DEGREES[k])
                .translate ({ -size / 2.0f, -size / 2.0f });
            transforms.add (transform);
            images[k].allocate (size, size, -1, transform);
        }
    }

    // Back to front, so the newest entry ends up on top.
    public override void snapshot (Gtk.Snapshot snapshot) {
        for (int k = images.length - 1; k >= 0; k--) {
            var image = images[k];
            if (!image.visible) {
                continue;
            }
            if (DEGREES[k] == 0) {
                snapshot_child (image, snapshot);
            } else {
                var size = slot_size (k);
                StackRender.append_supersampled (snapshot, image, transforms[k], size, size, render_scale);
            }
        }
    }
}
