// Gvt.Terminal in a presented window, against real children. Compiled with
// the library sources, so the tests can reach the internal engine and
// renderer.

class Exits : Object {
    public int count = 0;
    public int status = 0;

    public Exits (Gvt.Terminal t) {
        t.child_exited.connect ((s) => {
            count++;
            status = s;
        });
    }

    public void wait () {
        assert_true (TestUtil.wait_until (() => count > 0));
    }
}

static void test_spawn () {
    var t = TestUtil.new_terminal ();
    var window = TestUtil.present (t);
    var exits = new Exits (t);
    TestUtil.spawn (t, { "sh", "-c", "printf 'hi\\n'; exit 3" });
    exits.wait ();
    assert_cmpint (exits.count, CompareOperator.EQ, 1);
    assert_true (Process.if_exited (exits.status));
    assert_cmpint (Process.exit_status (exits.status), CompareOperator.EQ, 3);

    size_t len;
    var text = t.get_text_range_format (Gvt.Format.TEXT, 0, 0, 0, 2, out len);
    assert_cmpstr (text, CompareOperator.EQ, "hi");
    assert_cmpuint ((uint) len, CompareOperator.EQ, 2);
    assert_null (t.get_text_range_format (Gvt.Format.HTML, 0, 0, 0, 2, out len));
    window.destroy ();
}

static void test_exec_error () {
    var t = TestUtil.new_terminal ();
    var window = TestUtil.present (t);
    Error? failure = null;
    bool done = false;
    t.spawn_async (Gvt.PtyFlags.DEFAULT, null, { "/nonexistent" }, null, 0, null, -1, null,
                   (term, pid, error) => {
        failure = error;
        done = true;
    });
    // The callback comes from the main loop, never from inside spawn_async.
    assert_false (done);
    assert_true (TestUtil.wait_until (() => done));
    assert_true (failure != null);
    assert_null (t.get_pty ());
    window.destroy ();
}

static void test_title () {
    var t = TestUtil.new_terminal ();
    var window = TestUtil.present (t);
    int changes = 0;
    t.window_title_changed.connect (() => changes++);
    TestUtil.spawn (t, { "sh", "-c", "printf '\\033]2;T\\007'; sleep 1" });
    assert_true (TestUtil.wait_until (() => changes > 0));
    assert_cmpstr (t.window_title, CompareOperator.EQ, "T");
    window.destroy ();
}

static void test_cursor () {
    var t = TestUtil.new_terminal ();
    var window = TestUtil.present (t);
    var exits = new Exits (t);
    TestUtil.spawn (t, { "sh", "-c", "printf 'hi\\n'" });
    exits.wait ();
    long col, row;
    t.get_cursor_position (out col, out row);
    assert_cmpint ((int) col, CompareOperator.EQ, 0);
    assert_cmpint ((int) row, CompareOperator.EQ, 1);
    window.destroy ();
}

static void test_zero_size () {
    var t = TestUtil.new_terminal ();
    // Measured first, as a parent would. Fatal warnings make any warning
    // from here fail the test.
    TestUtil.measure (t);
    t.allocate (0, 0, -1, null);
    assert_cmpuint (t.engine.cols, CompareOperator.EQ, 1);
    assert_cmpuint (t.engine.rows, CompareOperator.EQ, 1);
    // Smaller than one cell is also one cell.
    t.allocate ((int) t.get_char_width () - 1, (int) t.get_char_height () - 1, -1, null);
    assert_cmpuint (t.engine.cols, CompareOperator.EQ, 1);
    assert_cmpuint (t.engine.rows, CompareOperator.EQ, 1);
}

static void test_font_scale () {
    var t = TestUtil.new_terminal ();
    var width = t.get_char_width ();
    int notified = 0;
    t.notify["font-scale"].connect (() => notified++);
    t.increase_font_size ();
    assert_cmpfloat_with_epsilon (t.font_scale, 1.2, 1e-9);
    assert_cmpint (notified, CompareOperator.GE, 1);
    assert_cmpint ((int) t.get_char_width (), CompareOperator.GT, (int) width);
    t.decrease_font_size ();
    assert_cmpfloat_with_epsilon (t.font_scale, 1.0, 1e-9);
    assert_cmpint ((int) t.get_char_width (), CompareOperator.EQ, (int) width);
    t.font_scale = 100;
    assert_cmpfloat_with_epsilon (t.font_scale, 4.0, 1e-9);
    t.font_scale = 0;
    assert_cmpfloat_with_epsilon (t.font_scale, 0.25, 1e-9);
}

static void test_vadjustment () {
    var t = TestUtil.new_terminal ();
    var scroller = new Gtk.ScrolledWindow () { vadjustment = t.vadjustment, child = t };
    assert_true (scroller.vadjustment == t.vadjustment);
    TestUtil.measure (t);
    t.allocate ((int) t.get_char_width () * 20, (int) t.get_char_height () * 5, -1, null);
    assert_cmpuint (t.engine.rows, CompareOperator.EQ, 5);

    var lines = new StringBuilder ();
    for (var i = 0; i < 20; i++) {
        lines.append ("line %d\r\n".printf (i));
    }
    t.process_output (lines.str.data);
    assert_true (TestUtil.wait_until (() => t.vadjustment.upper >= 20));
    assert_cmpfloat (t.vadjustment.page_size, CompareOperator.EQ, 5);
    // At the bottom: the viewport starts at the active screen.
    assert_cmpfloat (t.vadjustment.value, CompareOperator.EQ, t.engine.scrollback_rows);

    // Moving the adjustment scrolls the viewport.
    t.vadjustment.value = 0;
    assert_cmpint ((int) t.engine.viewport_top, CompareOperator.EQ, 0);
}

static void test_engine_failed () {
    var t = TestUtil.new_terminal ();
    var window = TestUtil.present (t);
    var exits = new Exits (t);
    var pid = TestUtil.spawn (t, { "sleep", "100" });
    t.engine.failed ();
    assert_cmpint (exits.count, CompareOperator.EQ, 1);
    assert_cmpint (exits.status, CompareOperator.EQ, -1);
    // The child was hung up, and no second child_exited follows.
    assert_true (TestUtil.wait_until (() => Posix.kill ((Posix.pid_t) pid, 0) != 0));
    TestUtil.run_for (100);
    assert_cmpint (exits.count, CompareOperator.EQ, 1);
    window.destroy ();
}

static void test_one_draw_per_tick () {
    var t = TestUtil.new_terminal ();
    var window = TestUtil.present (t);
    int changed = 0;
    t.contents_changed.connect (() => changed++);
    var frames = t.renderer.frames;
    // 200 reads' worth of output inside one frame.
    for (var i = 0; i < 200; i++) {
        t.process_output ("chunk %d\r\n".printf (i).data);
    }
    TestUtil.run_for (300);
    var drawn = t.renderer.frames - frames;
    assert_cmpuint (drawn, CompareOperator.GE, 1);
    assert_cmpuint (drawn, CompareOperator.LE, 2);
    assert_cmpint (changed, CompareOperator.EQ, 1);
    window.destroy ();
}

int main (string[] args) {
    Test.init (ref args);
    Gtk.init ();
    Test.add_func ("/terminal/spawn", test_spawn);
    Test.add_func ("/terminal/exec-error", test_exec_error);
    Test.add_func ("/terminal/title", test_title);
    Test.add_func ("/terminal/cursor", test_cursor);
    Test.add_func ("/terminal/zero-size", test_zero_size);
    Test.add_func ("/terminal/font-scale", test_font_scale);
    Test.add_func ("/terminal/vadjustment", test_vadjustment);
    Test.add_func ("/terminal/engine-failed", test_engine_failed);
    Test.add_func ("/terminal/one-draw-per-tick", test_one_draw_per_tick);
    return Test.run ();
}
