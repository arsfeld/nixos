// Renders a presented Gvt.Terminal to a texture and samples pixels at cell
// centres. No golden images: only sizes and colours that do not depend on
// how the font draws.

class Pixels {
    public int width;
    public int height;
    private uint8[] data;

    public Pixels (Gvt.Terminal t) {
        var paintable = new Gtk.WidgetPaintable (t);
        var snapshot = new Gtk.Snapshot ();
        paintable.snapshot (snapshot, t.get_width (), t.get_height ());
        var node = snapshot.to_node ();
        assert_nonnull (node);
        var texture = t.get_native ().get_renderer ().render_texture (node, null);
        width = texture.get_width ();
        height = texture.get_height ();
        data = new uint8[width * height * 4];
        // Cairo's ARGB32 in native (little) endian: B, G, R, A per pixel.
        texture.download (data, width * 4);
    }

    public uint32 at (int x, int y) {
        var i = (y * width + x) * 4;
        return ((uint32) data[i + 2] << 16) | ((uint32) data[i + 1] << 8) | data[i];
    }

    /* The colour at the centre of cell (col, row). */
    public uint32 cell_centre (Gvt.Terminal t, int col, int row) {
        var w = (int) t.get_char_width ();
        var h = (int) t.get_char_height ();
        return at (col * w + w / 2, row * h + h / 2);
    }

    /* Whether any pixel inside cell (col, row) is close to pure red. */
    public bool cell_has_red (Gvt.Terminal t, int col, int row) {
        var w = (int) t.get_char_width ();
        var h = (int) t.get_char_height ();
        for (var y = row * h; y < (row + 1) * h; y++) {
            for (var x = col * w; x < (col + 1) * w; x++) {
                var p = at (x, y);
                if ((p >> 16) > 0xc0 && ((p >> 8) & 0xff) < 0x50 && (p & 0xff) < 0x50) {
                    return true;
                }
            }
        }
        return false;
    }
}

static Gdk.RGBA rgba (string spec) {
    var c = Gdk.RGBA ();
    assert_true (c.parse (spec));
    return c;
}

/* white on black; palette 1 is pure red, 7 grey, the rest black. */
static void set_test_colors (Gvt.Terminal t) {
    var palette = new Gdk.RGBA[16];
    for (var i = 0; i < 16; i++) {
        palette[i] = rgba ("#000000");
    }
    palette[1] = rgba ("#ff0000");
    palette[7] = rgba ("#808080");
    t.set_colors (rgba ("#ffffff"), rgba ("#000000"), palette);
}

static void test_colors () {
    var t = TestUtil.new_terminal ();
    var window = TestUtil.present (t);
    set_test_colors (t);
    t.process_output ("\x1b[41m  \x1b[0m".data);
    TestUtil.run_for (100);
    var px = new Pixels (t);
    assert_cmphex (px.cell_centre (t, 0, 0), CompareOperator.EQ, 0xff0000);
    assert_cmphex (px.cell_centre (t, 1, 0), CompareOperator.EQ, 0xff0000);
    assert_cmphex (px.cell_centre (t, 5, 0), CompareOperator.EQ, 0x000000);
    window.destroy ();
}

static void test_wide () {
    var t = TestUtil.new_terminal ();
    var window = TestUtil.present (t);
    set_test_colors (t);
    // A grey wide glyph, then a red 'a', which belongs in column 2.
    t.process_output ("\x1b[37m中\x1b[31ma\x1b[0m".data);
    TestUtil.run_for (100);
    long col, row;
    t.get_cursor_position (out col, out row);
    assert_cmpint ((int) col, CompareOperator.EQ, 3);
    var px = new Pixels (t);
    assert_true (px.cell_has_red (t, 2, 0));
    assert_false (px.cell_has_red (t, 1, 0));
    assert_false (px.cell_has_red (t, 3, 0));
    window.destroy ();
}

static void test_size () {
    var t = TestUtil.new_terminal ();
    var window = TestUtil.present (t);
    assert_cmpuint (t.engine.cols, CompareOperator.EQ, 80);
    assert_cmpuint (t.engine.rows, CompareOperator.EQ, 24);
    var px = new Pixels (t);
    assert_cmpint (px.width, CompareOperator.GE, 80 * (int) t.get_char_width ());
    assert_cmpint (px.height, CompareOperator.GE, 24 * (int) t.get_char_height ());
    window.destroy ();
}

int main (string[] args) {
    Test.init (ref args);
    Gtk.init ();
    Test.add_func ("/renderer/colors", test_colors);
    Test.add_func ("/renderer/wide", test_wide);
    Test.add_func ("/renderer/size", test_size);
    return Test.run ();
}
