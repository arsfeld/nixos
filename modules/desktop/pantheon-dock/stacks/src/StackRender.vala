/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Painting a tilted widget cleanly. GSK draws rotated text and rounded clips
 * with jagged edges (see the 2026-10-31 dock stacks polish spec), so tilted
 * widgets are drawn upright into a texture at twice the surface scale (times the item's zoom render_scale), and the
 * texture is filtered as it is rotated and scaled back down.
 */

namespace Dock.StackRender {
    // Also the oversample IconResolution must look tilted icons up at, or the
    // texture below holds a 1× bitmap stretched to 2×.
    public const int OVERSAMPLE = 2;
    // Room for what a widget paints outside its allocation: the fan pills'
    // box-shadow and the icons' -gtk-icon-shadow (StackStyle).
    private const float PAD = 4;

    /*
     * Paints widget, of the given size, under transform. The caller must not
     * also snapshot_child () it. The widget's own CSS box, outline, opacity and
     * clip are skipped, so pass widgets with no visible box of their own.
     */
    public void append_supersampled (Gtk.Snapshot snapshot, Gtk.Widget widget, Gsk.Transform transform, float width, float height, int render_scale = 1) {
        var native = widget.get_native ();
        if (native == null || width <= 0 || height <= 0) {
            return;
        }
        // render_scale: a zoomed item scales this texture up again afterwards.
        var scale = (float) (OVERSAMPLE * render_scale * native.get_surface ().get_scale ());

        var inner = new Gtk.Snapshot ();
        inner.scale (scale, scale);
        inner.translate ({ PAD, PAD });
        // Not Gtk.WidgetPaintable: asked from inside a snapshot, it paints nothing
        // here (an empty node, so the row vanished). The widget's own snapshot
        // vfunc draws its content and children upright, but not its own CSS box
        // (background, border, box-shadow, outline), opacity or clip.
        widget.snapshot (inner);
        var node = inner.to_node ();
        if (node == null) {
            return;
        }

        Graphene.Rect viewport = { { 0, 0 }, { (width + 2 * PAD) * scale, (height + 2 * PAD) * scale } };
        var texture = native.get_renderer ().render_texture (node, viewport);

        Graphene.Rect bounds = { { -PAD, -PAD }, { width + 2 * PAD, height + 2 * PAD } };
        snapshot.save ();
        snapshot.transform (transform);
        snapshot.append_scaled_texture (texture, TRILINEAR, bounds);
        snapshot.restore ();
    }
}
