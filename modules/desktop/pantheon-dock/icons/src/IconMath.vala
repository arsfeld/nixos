/*
 * SPDX-License-Identifier: GPL-3.0
 */

/**
 * How big an icon's bitmap must be, kept free of GTK so it can be unit tested.
 */
namespace Dock.IconMath {
    /**
     * The whole-number scale an item zoomed by zoom must rasterize its icons at:
     * 1 at rest, so resting icons keep their native bitmaps, and otherwise the
     * next whole number at or above the zoom, so the bitmap is only ever shrunk.
     */
    public int render_scale_for (double zoom) {
        if (zoom <= 1.0) {
            return 1;
        }
        return (int) Math.ceil (zoom);
    }

    /** The scale to look an icon up at, for IconTheme.lookup_by_gicon. */
    public int lookup_scale (int surface_scale, int oversample, int render_scale) {
        return surface_scale * oversample * render_scale;
    }
}
