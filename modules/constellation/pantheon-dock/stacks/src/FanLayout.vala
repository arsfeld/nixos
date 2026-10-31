/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Rows stacked bottom-up in one column, the way a macOS fan curves: row 0 sits
 * at the bottom, nearest the dock, and each row above it drifts a little
 * further right and tilts a little more, so the column bends gently to the
 * right as it rises. Every row ends in an ICON_SIZE-wide icon, and the icons
 * form the column: it is centred horizontally, so the popover (which GTK
 * centres on the dock tile) puts the column right over the tile. The rows'
 * labels hang off to the left of it.
 */

public class Dock.FanLayout : Gtk.Widget {
    public const int ICON_SIZE = 48;
    private const int ROW_HEIGHT = 56;
    // At the top of a full fan: the icon column's offset to the right, and the
    // row's tilt. Both grow from 0 at the bottom row.
    private const double MAX_DRIFT = 44;
    private const double MAX_DEGREES = 5;
    // Rows the curve is scaled for, so a short fan is the bottom of a full one
    // rather than a squashed copy of it.
    private const int FULL_ROWS = FanPopover.MAX_ITEMS + 1;
    // Slack around the rotated rows, so their corners never touch the edge of
    // the popover surface, where they would be clipped.
    private const int MARGIN = 8;

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

        double half_width, height;
        extent (out half_width, out height);
        minimum = natural = orientation == HORIZONTAL
            ? 2 * ((int) Math.ceil (half_width) + MARGIN)
            : (int) Math.ceil (height) + MARGIN;
    }

    public override void size_allocate (int width, int height, int baseline) {
        // Origin: the bottom of row 0, centred.
        float origin_x = width / 2.0f;
        float origin_y = height;

        for (uint i = 0; i < rows.length; i++) {
            var row = rows[i];
            var row_w = row_width (row);

            // Pivot on the icon's centre, so the icons stay in one column.
            var transform = new Gsk.Transform ()
                .translate ({ origin_x + (float) drift (i), origin_y - ROW_HEIGHT * (i + 0.5f) })
                .rotate ((float) degrees (i))
                .translate ({ -(row_w - ICON_SIZE / 2.0f), -ROW_HEIGHT / 2.0f });
            row.allocate (row_w, ROW_HEIGHT, -1, transform);
        }
    }

    /*
     * The bounds of all rows once rotated, measured from the bottom of the
     * centre column: half_width is the larger reach to either side.
     */
    private void extent (out double half_width, out double height) {
        half_width = 0;
        height = 0;
        for (uint i = 0; i < rows.length; i++) {
            var row_w = row_width (rows[i]);
            var radians = degrees (i) * Math.PI / 180.0;
            var cos_a = Math.cos (radians);
            var sin_a = Math.sin (radians);
            double[] xs = { -(row_w - ICON_SIZE / 2.0), ICON_SIZE / 2.0 };
            double[] ys = { -ROW_HEIGHT / 2.0, ROW_HEIGHT / 2.0 };
            foreach (var x in xs) {
                foreach (var y in ys) {
                    // Gsk rotates clockwise on screen; y grows downwards.
                    var px = drift (i) + x * cos_a - y * sin_a;
                    var py = -ROW_HEIGHT * (i + 0.5) + x * sin_a + y * cos_a;
                    half_width = double.max (half_width, px.abs ());
                    height = double.max (height, -py);
                }
            }
        }
    }

    private static int row_width (Gtk.Widget row) {
        int min, nat, min_b, nat_b;
        row.measure (HORIZONTAL, -1, out min, out nat, out min_b, out nat_b);
        return nat;
    }

    private static double progress (uint i) {
        return double.min (1.0, i / (double) (FULL_ROWS - 1));
    }

    /* Rightward drift of row i's icon: flat near the dock, growing with height. */
    private static double drift (uint i) {
        var t = progress (i);
        return MAX_DRIFT * t * t;
    }

    /*
     * Row i's clockwise tilt, which lifts its label: the slope of the drift
     * curve, damped so even the top row tilts only a few degrees.
     */
    private static double degrees (uint i) {
        return MAX_DEGREES * progress (i);
    }
}
