// Selection and the clipboard: Gvt.Terminal's VTE selection API, the mouse
// selection path through Input, and OSC 52 against the display clipboard.
// Runs with GSETTINGS_BACKEND=memory, so clipboard-read can be flipped here.

/* Overrides the action signals as elementary does, which also checks the
 * pattern compiles against Terminal's declaration. */
class CopyCounting : Gvt.Terminal {
    public int copies = 0;
    public int pastes = 0;

    protected override void copy_clipboard () {
        copies++;
        base.copy_clipboard ();
    }

    protected override void paste_clipboard () {
        pastes++;
        base.paste_clipboard ();
    }
}

/* The display clipboard's text, read through the main loop. */
static string? clipboard_text (Gdk.Clipboard clipboard) {
    string? text = null;
    bool done = false;
    clipboard.read_text_async.begin (null, (obj, res) => {
        try {
            text = clipboard.read_text_async.end (res);
        } catch (Error e) {
            text = null;
        }
        done = true;
    });
    assert_true (TestUtil.wait_until (() => done, 5));
    return text;
}

/* A terminal allocated to cols x rows cells, not in a window. */
static Gvt.Terminal sized (int cols, int rows) {
    var t = TestUtil.new_terminal ();
    TestUtil.measure (t);
    var cw = (int) t.get_char_width ();
    var ch = (int) t.get_char_height ();
    t.allocate (cols * cw, rows * ch, -1, null);
    assert_cmpuint (t.engine.cols, CompareOperator.EQ, cols);
    return t;
}

static void test_all () {
    var t = new CopyCounting ();
    t.set_font (Pango.FontDescription.from_string ("DejaVu Sans Mono 10"));
    t.process_output ("one\r\ntwo".data);
    assert_false (t.get_has_selection ());
    t.select_all ();
    assert_true (t.get_has_selection ());
    t.copy_clipboard.emit ();
    assert_cmpint (t.copies, CompareOperator.EQ, 1);
    assert_cmpstr (clipboard_text (t.get_clipboard ()), CompareOperator.EQ, "one\ntwo");
}

static void test_wrapped () {
    var t = sized (10, 5);
    t.process_output ("xxxxxxxxxxxxxxx".data);
    var cw = t.get_char_width ();
    var ch = t.get_char_height ();
    // Press in the left part of (0,0); drag into the right part of (4,1).
    t.input.button (true, 1, 1, 1, 0, 1);
    t.input.motion (4 * cw + cw * 0.9, ch * 1.5, Gdk.ModifierType.BUTTON1_MASK);
    t.input.button (false, 1, 4 * cw + cw * 0.9, ch * 1.5, 0, 1);
    assert_true (t.get_has_selection ());
    assert_cmpstr (t.engine.selection_text (), CompareOperator.EQ, "xxxxxxxxxxxxxxx");
    // Ending a mouse selection sets the primary clipboard.
    assert_cmpstr (clipboard_text (t.get_primary_clipboard ()), CompareOperator.EQ, "xxxxxxxxxxxxxxx");
}

static void test_word () {
    var t = sized (20, 5);
    t.process_output ("foo bar".data);
    var cw = t.get_char_width ();
    var ch = t.get_char_height ();
    t.input.button (true, 1, 5 * cw + cw / 2, ch / 2, 0, 2);
    t.input.button (false, 1, 5 * cw + cw / 2, ch / 2, 0, 2);
    assert_cmpstr (t.engine.selection_text (), CompareOperator.EQ, "bar");
    // Other buttons never select: a right click leaves it alone.
    t.input.button (true, 3, 1, 1, 0, 1);
    t.input.button (false, 3, 1, 1, 0, 1);
    assert_cmpstr (t.engine.selection_text (), CompareOperator.EQ, "bar");
}

static void test_changed () {
    var t = TestUtil.new_terminal ();
    t.process_output ("text".data);
    int changes = 0;
    t.selection_changed.connect (() => changes++);
    t.select_all ();
    t.unselect_all ();
    assert_cmpint (changes, CompareOperator.EQ, 2);
    assert_false (t.get_has_selection ());
    // Nothing selected: nothing changes.
    t.unselect_all ();
    assert_cmpint (changes, CompareOperator.EQ, 2);
}

/* What the engine answers the program with, as it goes to the PTY. */
class Replies : Object {
    public StringBuilder bytes = new StringBuilder ();

    public Replies (Gvt.Terminal t) {
        t.engine.write_pty.connect ((b) => bytes.append_len ((string) b, b.length));
    }
}

static void test_osc52_write () {
    var t = TestUtil.new_terminal ();
    t.process_output ("\x1b]52;c;aGVsbG8=\x07".data);
    assert_cmpstr (clipboard_text (t.get_clipboard ()), CompareOperator.EQ, "hello");
}

/* Puts text on the display clipboard and waits until t's cached copy has it. */
static void set_clipboard (Gvt.Terminal t, string text) {
    t.get_clipboard ().set_text (text);
    assert_true (TestUtil.wait_until (() => t.clipboard.cached == text, 5));
}

static void test_osc52_read_off () {
    var t = TestUtil.new_terminal ();
    set_clipboard (t, "secret");
    var replies = new Replies (t);
    t.process_output ("\x1b]52;c;?\x07".data);
    assert_false ("c2VjcmV0" in replies.bytes.str);
}

static void test_osc52_read_on () {
    var settings = new Settings ("io.github.arsfeld.gvt");
    settings.set_boolean ("clipboard-read", true);
    var t = TestUtil.new_terminal ();
    set_clipboard (t, "secret");
    var replies = new Replies (t);
    t.process_output ("\x1b]52;c;?\x07".data);
    assert_true ("c2VjcmV0" in replies.bytes.str);
    settings.reset ("clipboard-read");
}

static void test_paste () {
    var t = new CopyCounting ();
    t.set_font (Pango.FontDescription.from_string ("DejaVu Sans Mono 10"));
    var window = TestUtil.present (t);
    TestUtil.spawn (t, { "cat" });
    set_clipboard (t, "ls");
    t.paste_clipboard.emit ();
    assert_cmpint (t.pastes, CompareOperator.EQ, 1);
    assert_true (TestUtil.wait_until (() => {
        size_t len;
        return t.get_text_range_format (Gvt.Format.TEXT, 0, 0, 0, 2, out len) == "ls";
    }, 5));
    window.destroy ();
}

public static int main (string[] args) {
    Test.init (ref args);
    Gtk.init ();
    Test.add_func ("/selection/all", test_all);
    Test.add_func ("/selection/wrapped", test_wrapped);
    Test.add_func ("/selection/word", test_word);
    Test.add_func ("/selection/changed", test_changed);
    Test.add_func ("/clipboard/osc52-write", test_osc52_write);
    Test.add_func ("/clipboard/osc52-read-off", test_osc52_read_off);
    Test.add_func ("/clipboard/osc52-read-on", test_osc52_read_on);
    Test.add_func ("/clipboard/paste", test_paste);
    return Test.run ();
}
