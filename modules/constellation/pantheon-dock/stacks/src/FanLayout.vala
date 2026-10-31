/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Rows stacked bottom-up in one column, the way a macOS fan curves: row 0 sits
 * at the bottom, nearest the dock, and each row above it drifts a little
 * further right and tilts a little more (FanMath), so the column bends gently
 * to the right as it rises. Every row ends in an ICON_SIZE-wide icon, and the
 * icons form the column: it is centred horizontally, so the popover (which GTK
 * centres on the dock tile) puts the column right over the tile. The rows'
 * labels hang off to the left of it.
 *
 * Tilted rows are painted through StackRender, so their pills and text stay
 * smooth. Allocation still carries the real transform, so hover, clicks and
 * drags land where the row is drawn.
 */

public class Dock.FanLayout : Gtk.Widget {
    public const int ICON_SIZE = FanMath.ICON_SIZE;
    // Slack around the rows: 8 px so rotated corners never touch the popover
    // surface's edge, where they would be clipped, plus room for a clicked
    // row's icon to grow by ICON_SIZE * FanMath.ZOOM / 2 (about 15 px) a side.
    private const int MARGIN = 24;

    /* The launch animation's progress: 0 = open, 1 = folded into the tile. */
    public double collapse { get; set; default = 0; }

    private GenericArray<Gtk.Widget> rows = new GenericArray<Gtk.Widget> ();
    // From the last allocation, per row: what snapshot () paints with.
    private GenericArray<Gsk.Transform> transforms = new GenericArray<Gsk.Transform> ();
    private double[] tilts = {};
    private double[] alphas = {};
    // The row being launched, and its icon, which is drawn again on top as a
    // "ghost" that grows and fades (FanMath.ghost_scale).
    private int clicked = -1;
    private Gtk.Widget? clicked_icon = null;
    private Graphene.Point[] pivots = {};

    construct {
        overflow = VISIBLE;
        notify["collapse"].connect (on_collapse_changed);
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
        clicked = -1;
        clicked_icon = null;
        queue_resize ();
    }

    public Gtk.Widget? row_at (uint i) {
        return i < rows.length ? rows[i] : null;
    }

    /* Starts a launch from row, whose icon widget is icon; collapse then drives it. */
    public void start_launch (Gtk.Widget row, Gtk.Widget icon) {
        uint index;
        clicked = rows.find (row, out index) ? (int) index : -1;
        clicked_icon = icon;
        // No second click while the fan folds away.
        can_target = false;
        queue_allocate ();
    }

    public void reset_launch () {
        clicked = -1;
        clicked_icon = null;
        can_target = true;
        collapse = 0;
    }

    public override void dispose () {
        clear ();
        base.dispose ();
    }

    private void on_collapse_changed () {
        queue_allocate ();
        queue_draw ();
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

        transforms = new GenericArray<Gsk.Transform> ();
        tilts = new double[rows.length];
        alphas = new double[rows.length];
        pivots = new Graphene.Point[rows.length];

        for (uint i = 0; i < rows.length; i++) {
            var row = rows[i];
            var row_w = row_width (row);
            var pose = FanMath.pose (i, collapse, i == clicked);
            Graphene.Point pivot = { origin_x + (float) pose.x, origin_y + (float) pose.y };
            pivots[i] = pivot;

            // Pivot on the icon's centre, so the icons stay in one column.
            var transform = new Gsk.Transform ()
                .translate (pivot)
                .rotate ((float) pose.degrees)
                .translate ({ -(row_w - ICON_SIZE / 2.0f), -FanMath.ROW_HEIGHT / 2.0f });
            transforms.add (transform);
            tilts[i] = pose.degrees;
            alphas[i] = pose.alpha;
            row.allocate (row_w, FanMath.ROW_HEIGHT, -1, transform);
        }
    }

    public override void snapshot (Gtk.Snapshot snapshot) {
        for (uint i = 0; i < rows.length; i++) {
            var row = rows[i];
            if (alphas[i] <= 0) {
                continue;
            }
            snapshot.push_opacity (alphas[i]);
            if (tilts[i] == 0) {
                snapshot_child (row, snapshot);
            } else {
                StackRender.append_supersampled (snapshot, row, transforms[i], row.get_width (), row.get_height ());
            }
            snapshot.pop ();
        }

        if (clicked >= 0 && clicked_icon != null && collapse < 1) {
            // The icon sits centred on the row's pivot, so zoom about the pivot.
            var width = clicked_icon.get_width ();
            var height = clicked_icon.get_height ();
            var scale = (float) FanMath.ghost_scale (collapse);
            var transform = new Gsk.Transform ()
                .translate (pivots[clicked])
                .rotate ((float) tilts[clicked])
                .scale (scale, scale)
                .translate ({ -width / 2.0f, -height / 2.0f });
            snapshot.push_opacity (1 - collapse);
            StackRender.append_supersampled (snapshot, clicked_icon, transform, width, height);
            snapshot.pop ();
        }
    }

    /*
     * The bounds of all rows once rotated (in the open fan, which is the
     * largest), measured from the bottom of the centre column: half_width is
     * the larger reach to either side.
     */
    private void extent (out double half_width, out double height) {
        half_width = 0;
        height = 0;
        for (uint i = 0; i < rows.length; i++) {
            var row_w = row_width (rows[i]);
            var pose = FanMath.pose (i, 0, false);
            var radians = pose.degrees * Math.PI / 180.0;
            var cos_a = Math.cos (radians);
            var sin_a = Math.sin (radians);
            double[] xs = { -(row_w - ICON_SIZE / 2.0), ICON_SIZE / 2.0 };
            double[] ys = { -FanMath.ROW_HEIGHT / 2.0, FanMath.ROW_HEIGHT / 2.0 };
            foreach (var x in xs) {
                foreach (var y in ys) {
                    // Gsk rotates clockwise on screen; y grows downwards.
                    var px = pose.x + x * cos_a - y * sin_a;
                    var py = pose.y + x * sin_a + y * cos_a;
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
}
