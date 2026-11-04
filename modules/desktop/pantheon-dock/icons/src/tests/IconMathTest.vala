/*
 * SPDX-License-Identifier: GPL-3.0
 */

int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/icon-math/rest-is-native", () => {
        assert (Dock.IconMath.render_scale_for (1.0) == 1);
    });

    Test.add_func ("/icon-math/never-below-one", () => {
        assert (Dock.IconMath.render_scale_for (0.5) == 1);
    });

    Test.add_func ("/icon-math/zoom-rounds-up", () => {
        // Any magnification at all needs the next whole scale, so the bitmap is only ever shrunk.
        assert (Dock.IconMath.render_scale_for (1.001) == 2);
        assert (Dock.IconMath.render_scale_for (1.75) == 2);
        assert (Dock.IconMath.render_scale_for (2.0) == 2);
        // 104 / 48, the largest zoom-size that fits the headroom.
        assert (Dock.IconMath.render_scale_for (104.0 / 48.0) == 3);
    });

    Test.add_func ("/icon-math/lookup-scale", () => {
        assert (Dock.IconMath.lookup_scale (1, 1, 1) == 1);
        assert (Dock.IconMath.lookup_scale (1, 2, 1) == 2);
        assert (Dock.IconMath.lookup_scale (1, 2, 2) == 4);
        assert (Dock.IconMath.lookup_scale (2, 1, 2) == 4);
        assert (Dock.IconMath.lookup_scale (2, 2, 2) == 8);
    });

    return Test.run ();
}
