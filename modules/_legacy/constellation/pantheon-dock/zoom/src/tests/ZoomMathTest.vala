/*
 * SPDX-License-Identifier: GPL-3.0
 */

private const double SLOT = 60.0;
private const double PEAK = 1.75;

private bool near (double a, double b) {
    return Math.fabs (a - b) < 1e-9;
}

int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/zoom-math/peak-at-pointer", () => {
        assert (near (Dock.ZoomMath.factor (0, SLOT, PEAK), PEAK));
    });

    Test.add_func ("/zoom-math/symmetric", () => {
        assert (near (Dock.ZoomMath.factor (37, SLOT, PEAK), Dock.ZoomMath.factor (-37, SLOT, PEAK)));
        assert (near (Dock.ZoomMath.factor (125, SLOT, PEAK), Dock.ZoomMath.factor (-125, SLOT, PEAK)));
    });

    Test.add_func ("/zoom-math/falls-off", () => {
        var f0 = Dock.ZoomMath.factor (0, SLOT, PEAK);
        var f1 = Dock.ZoomMath.factor (30, SLOT, PEAK);
        var f2 = Dock.ZoomMath.factor (90, SLOT, PEAK);
        var f3 = Dock.ZoomMath.factor (150, SLOT, PEAK);
        assert (f0 > f1 && f1 > f2 && f2 > f3 && f3 > 1.0);
    });

    Test.add_func ("/zoom-math/flat-beyond-range", () => {
        assert (Dock.ZoomMath.factor (SLOT * Dock.ZoomMath.RANGE, SLOT, PEAK) == 1.0);
        assert (Dock.ZoomMath.factor (500, SLOT, PEAK) == 1.0);
        assert (Dock.ZoomMath.factor (-500, SLOT, PEAK) == 1.0);
        assert (Dock.ZoomMath.factor (SLOT * Dock.ZoomMath.RANGE - 1, SLOT, PEAK) > 1.0);
    });

    Test.add_func ("/zoom-math/no-zoom-when-peak-is-one", () => {
        assert (Dock.ZoomMath.factor (0, SLOT, 1.0) == 1.0);
    });

    Test.add_func ("/zoom-math/rest-x", () => {
        // Unzoomed, resting and zoomed coordinates coincide.
        assert (near (Dock.ZoomMath.rest_x (123, 600, 600), 123));
        // The dock grew by 80 px, 40 px on each side, so the pointer sits 40 px further right in it.
        assert (near (Dock.ZoomMath.rest_x (163, 680, 600), 123));
        // Round trip.
        var p = 271.5;
        var r = Dock.ZoomMath.rest_x (p, 713, 600);
        assert (near (r + (713 - 600) / 2.0, p));
    });

    Test.add_func ("/zoom-math/clamp-fits-headroom", () => {
        // 48 px icons with 6 px top padding under a 64 px headroom.
        var max = Dock.ZoomMath.max_zoom_size (48, 54, 64);
        assert (max == 104);
        assert (Dock.ZoomMath.rise (54, max / 48.0) <= 64.0);
        assert (Dock.ZoomMath.rise (54, (max + 1) / 48.0) > 64.0);
        assert (Dock.ZoomMath.rise (54, 1.0) == 0.0);
    });

    return Test.run ();
}
