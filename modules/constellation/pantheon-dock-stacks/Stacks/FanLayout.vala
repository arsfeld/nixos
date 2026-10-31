/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Rows stacked bottom-up on an arc: row 0 sits at the bottom, nearest the
 * dock, and each row above it drifts right and tilts a little more, the way a
 * macOS fan curves. Rows are right-aligned on their icon.
 */

public class Dock.FanLayout : Gtk.Widget {
    private const int ROW_HEIGHT = 56;
    private const double STEP_DEGREES = 2.0;
    // Horizontal drift of row i is ARC_RADIUS * (1 - cos (i * STEP)).
    private const double ARC_RADIUS = 1200;

    private GenericArray<Gtk.Widget> rows = new GenericArray<Gtk.Widget> ();

    construct {
        overflow = VISIBLE;
    }

    public void append_row (Gtk.Widget row) {
        row.set_parent (this);
        rows.add (row);
        queue_resize ();
    }

    public void clear () {
        foreach (var row in rows) {
            row.unparent ();
        }
        rows.length = 0;
        queue_resize ();
    }

    public override void dispose () {
        clear ();
        base.dispose ();
    }

    public override Gtk.SizeRequestMode get_request_mode () {
        return CONSTANT_SIZE;
    }

    public override void measure (Gtk.Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
        minimum_baseline = natural_baseline = -1;

        if (orientation == VERTICAL) {
            minimum = natural = ROW_HEIGHT * rows.length;
            return;
        }

        int widest = 0;
        foreach (var row in rows) {
            widest = int.max (widest, row_width (row));
        }
        minimum = natural = widest + (int) Math.ceil (drift (rows.length));
    }

    public override void size_allocate (int width, int height, int baseline) {
        var max_drift = drift (rows.length);
        for (uint i = 0; i < rows.length; i++) {
            var row = rows[i];
            var row_w = row_width (row);
            float right = (float) (width - (max_drift - drift (i + 1)));
            float middle = height - ROW_HEIGHT * (i + 0.5f);

            // Pivot on the row's right edge, where its icon is.
            var transform = new Gsk.Transform ()
                .translate ({ right, middle })
                .rotate (-(float) (i * STEP_DEGREES))
                .translate ({ -row_w, -ROW_HEIGHT / 2.0f });
            row.allocate (row_w, ROW_HEIGHT, -1, transform);
        }
    }

    private static int row_width (Gtk.Widget row) {
        int min, nat, min_b, nat_b;
        row.measure (HORIZONTAL, -1, out min, out nat, out min_b, out nat_b);
        return nat;
    }

    /* Drift of the row at 1-based height n; drift (rows.length) is the widest. */
    private static double drift (uint n) {
        if (n == 0) {
            return 0;
        }
        var radians = (n - 1) * STEP_DEGREES * Math.PI / 180.0;
        return ARC_RADIUS * (1 - Math.cos (radians));
    }
}
