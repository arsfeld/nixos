/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The fan's geometry, kept free of widgets so the unit test can check it.
 * Positions are of a row's icon centre, measured from the bottom of the fan's
 * centre column; y grows downwards, so rows sit at negative y.
 */

namespace Dock.FanMath {
    public const int MAX_ITEMS = 10;
    public const int ICON_SIZE = 48;
    public const int ROW_HEIGHT = 56;
    // At the top of a full fan: the icon column's offset to the right, and the
    // row's tilt. Both grow from 0 at the bottom row.
    private const double MAX_DRIFT = 44;
    private const double MAX_DEGREES = 5;
    // Rows the curve is scaled for (the entries plus the "Open in Files" row),
    // so a short fan is the bottom of a full one rather than a squashed copy of it.
    private const int FULL_ROWS = MAX_ITEMS + 1;
    /* How much a clicked row's icon grows by the end of the launch animation. */
    public const double ZOOM = 0.6;

    public struct Pose {
        public double x;
        public double y;
        /* Clockwise tilt about the icon centre. */
        public double degrees;
        public double alpha;
    }

    private double progress (uint i) {
        return double.min (1.0, i / (double) (FULL_ROWS - 1));
    }

    /* Rightward drift of row i's icon: flat near the dock, growing with height. */
    public double drift (uint i) {
        var t = progress (i);
        return MAX_DRIFT * t * t;
    }

    /*
     * Row i's clockwise tilt, which lifts its label: the slope of the drift
     * curve, damped so even the top row tilts only a few degrees.
     */
    public double degrees (uint i) {
        return MAX_DEGREES * progress (i);
    }

    /*
     * Row i at a point of the launch animation (collapse 0 = open, 1 = done).
     * The clicked row stays put and fades, while its ghost icon zooms (see
     * ghost_scale); every other row slides down into row 0's slot, untilting
     * and fading, so the fan runs back into the dock tile.
     */
    public Pose pose (uint i, double collapse, bool clicked) {
        var open_y = -ROW_HEIGHT * (i + 0.5);
        Pose result;
        if (clicked) {
            result = { drift (i), open_y, degrees (i), 1 - collapse };
        } else {
            var keep = 1 - collapse;
            result = { drift (i) * keep, open_y * keep - ROW_HEIGHT * 0.5 * collapse, degrees (i) * keep, keep };
        }
        return result;
    }

    public double ghost_scale (double collapse) {
        return 1 + ZOOM * collapse;
    }
}
