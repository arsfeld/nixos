/*
 * SPDX-License-Identifier: GPL-3.0
 */

/**
 * The dock zoom's arithmetic, kept free of GTK so it can be unit tested.
 */
namespace Dock.ZoomMath {
    /** How many resting slots on each side of the pointer the zoom reaches. */
    public const double RANGE = 3.0;

    /**
     * The zoom of an item whose resting centre is distance px from the
     * pointer: max_factor under the pointer, falling along a cosine bell to
     * exactly 1.0 at RANGE slots away.
     */
    public double factor (double distance, double slot, double max_factor) {
        var slots = Math.fabs (distance) / slot;
        if (slots >= RANGE) {
            return 1.0;
        }

        return 1.0 + (max_factor - 1.0) * (Math.cos (Math.PI * slots / RANGE) + 1.0) / 2.0;
    }

    /**
     * Maps a pointer x in the zoomed dock back to the resting dock. The
     * window is centred, so growing by n px moves its left edge n / 2 px left.
     */
    public double rest_x (double pointer_x, double zoomed_width, double rest_width) {
        return pointer_x - (zoomed_width - rest_width) / 2.0;
    }

    /**
     * The largest zoom-size whose scaled item still fits in headroom px above
     * the dock. item_height is the icon plus its top padding, which scales too.
     */
    public int max_zoom_size (int icon_size, int item_height, int headroom) {
        return icon_size + (int) Math.floor ((double) headroom * icon_size / item_height);
    }

    /** How far an item of item_height px rises when scaled by factor. */
    public double rise (int item_height, double factor) {
        return item_height * (factor - 1.0);
    }
}
