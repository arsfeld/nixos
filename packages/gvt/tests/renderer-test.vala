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

    /* The rightmost x in text row `row` whose pixel matches `pred`, or -1. */
    public int rightmost (Gvt.Terminal t, int row, PixelPredicate pred) {
        var h = (int) t.get_char_height ();
        for (var x = width - 1; x >= 0; x--) {
            for (var y = row * h; y < (row + 1) * h; y++) {
                if (pred (at (x, y))) {
                    return x;
                }
            }
        }
        return -1;
    }

    /* Whether any pixel inside cell (col, row) is close to pure red. */
    public bool cell_has_red (Gvt.Terminal t, int col, int row) {
        return cell_has (t, col, row, is_red);
    }

    /* Whether any pixel inside cell (col, row) matches `pred`. */
    public bool cell_has (Gvt.Terminal t, int col, int row, PixelPredicate pred) {
        var w = (int) t.get_char_width ();
        var h = (int) t.get_char_height ();
        for (var y = row * h; y < (row + 1) * h; y++) {
            for (var x = col * w; x < (col + 1) * w; x++) {
                if (pred (at (x, y))) {
                    return true;
                }
            }
        }
        return false;
    }
}

delegate bool PixelPredicate (uint32 p);

static bool is_red (uint32 p) {
    return (p >> 16) > 0xc0 && ((p >> 8) & 0xff) < 0x50 && (p & 0xff) < 0x50;
}

/* Red ink on black at any coverage, as the thin stems of a proportional
 * 'i' or 'l' are drawn: antialiased, never a pure red pixel. */
static bool is_red_ink (uint32 p) {
    return (p >> 16) > 0x40 && ((p >> 8) & 0xff) < 0x20 && (p & 0xff) < 0x20;
}

static bool is_green (uint32 p) {
    return (p >> 16) < 0x50 && ((p >> 8) & 0xff) > 0xc0 && (p & 0xff) < 0x50;
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

// NixOS's default bash PS1: bold green, with an OSC 0 title inside it.
const string NIXOS_PS1 = "\r\n\x1b[1;32m[\x1b]0;arosenfeld@machine: /home/arosenfeld\x07"
    + "arosenfeld@machine:/home/arosenfeld]$\x1b[0m ";

/* The prompt's last glyph, '$' in column 37, ends inside its own cell, so
 * text and cursor (column 39) agree about where the cells are. */
static void check_prompt (string font) {
    var t = TestUtil.new_terminal ();
    t.set_font (Pango.FontDescription.from_string (font));
    var window = TestUtil.present (t);
    var palette = new Gdk.RGBA[16];
    for (var i = 0; i < 16; i++) {
        palette[i] = rgba ("#000000");
    }
    palette[2] = rgba ("#00ff00");
    t.set_colors (rgba ("#ffffff"), rgba ("#000000"), palette);
    t.process_output (NIXOS_PS1.data);
    TestUtil.run_for (100);
    long col, row;
    t.get_cursor_position (out col, out row);
    assert_cmpint ((int) col, CompareOperator.EQ, 39);
    assert_cmpint ((int) row, CompareOperator.EQ, 1);
    var w = (int) t.get_char_width ();
    var px = new Pixels (t);
    var right = px.rightmost (t, 1, is_green);
    assert_cmpint (right, CompareOperator.GE, 37 * w);
    assert_cmpint (right, CompareOperator.LT, 38 * w);
    window.destroy ();
}

static void test_prompt () {
    check_prompt ("DejaVu Sans Mono 10");
}

/* elementary takes its font from a setting and fontconfig may hand back a
 * proportional face; VTE still draws it on the grid, one glyph per cell. */
static void test_prompt_proportional () {
    check_prompt ("DejaVu Sans 10");
}

/* A run of n cells, regular or bold, covers exactly n cells: each cell holds
 * ink and the last glyph ends inside the last cell. */
static void check_runs (string font, string glyphs) {
    var t = TestUtil.new_terminal ();
    t.set_font (Pango.FontDescription.from_string (font));
    var window = TestUtil.present (t);
    set_test_colors (t);
    t.process_output (("\x1b[31m" + glyphs + "\r\n\x1b[1m" + glyphs + "\x1b[0m").data);
    TestUtil.run_for (100);
    var w = (int) t.get_char_width ();
    var n = glyphs.char_count ();
    var px = new Pixels (t);
    for (var row = 0; row < 2; row++) {
        for (var col = 0; col < n; col++) {
            assert_true (px.cell_has (t, col, row, is_red_ink));
        }
        var right = px.rightmost (t, row, is_red_ink);
        assert_cmpint (right, CompareOperator.GE, (n - 1) * w);
        assert_cmpint (right, CompareOperator.LT, n * w);
    }
    window.destroy ();
}

static void test_runs () {
    check_runs ("DejaVu Sans Mono 10", "mmmmmmmmmmiiiiiiiiiiWWWWWWWWWW");
}

static void test_runs_proportional () {
    check_runs ("DejaVu Sans 10", "ililililililililililmmmmmmmmmm");
}

/* Box drawing and accented letters are narrow cells too, and stay on the
 * grid in a run, in a monospace face and a proportional one. */
static void test_runs_non_ascii () {
    check_runs ("DejaVu Sans Mono 10", "┌─┬─┐│╋═║éàüçñÉ");
    check_runs ("DejaVu Sans 10", "┌─┬─┐│╋═║éàüçñÉ");
}

/* A row of narrow cells in one style is one Pango layout, whatever its
 * characters: a layout per non-ASCII cell made box-drawing UIs (htop, mc,
 * tmux borders) cost a layout per cell. */
static void test_one_layout_per_run () {
    var t = TestUtil.new_terminal ();
    var window = TestUtil.present (t);
    set_test_colors (t);
    t.process_output ("\x1b[?25l┌──┬──┐ éàü ═║╋\r\nplain ascii".data);
    TestUtil.run_for (100);
    t.renderer.invalidate ();
    var before = t.renderer.layouts;
    var frames = t.renderer.frames;
    t.queue_draw ();
    assert_true (TestUtil.wait_until (() => t.renderer.frames > frames));
    // A blank ends a run: "┌──┬──┐", "éàü", "═║╋", "plain", "ascii".
    assert_cmpuint (t.renderer.layouts - before, CompareOperator.EQ, 5);
    window.destroy ();
}

int main (string[] args) {
    Test.init (ref args);
    Gtk.init ();
    Test.add_func ("/renderer/colors", test_colors);
    Test.add_func ("/renderer/wide", test_wide);
    Test.add_func ("/renderer/size", test_size);
    Test.add_func ("/renderer/prompt", test_prompt);
    Test.add_func ("/renderer/prompt-proportional", test_prompt_proportional);
    Test.add_func ("/renderer/runs", test_runs);
    Test.add_func ("/renderer/runs-proportional", test_runs_proportional);
    Test.add_func ("/renderer/runs-non-ascii", test_runs_non_ascii);
    Test.add_func ("/renderer/one-layout-per-run", test_one_layout_per_run);
    return Test.run ();
}
