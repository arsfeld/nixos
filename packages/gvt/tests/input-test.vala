// Input, driven with synthetic values rather than real key events. The bytes
// Input sends the child are captured from its `sent` signal, which is the
// one path every key, IM commit, mouse, focus and paste write goes through.

class Sent : Object {
    public ByteArray bytes = new ByteArray ();

    public Sent (Gvt.Input input) {
        input.sent.connect ((b) => bytes.append (b));
    }

    public string text () {
        var copy = new StringBuilder ();
        copy.append_len ((string) bytes.data, bytes.len);
        return copy.str;
    }

    public void clear () {
        bytes.set_size (0);
    }
}

/* An input method whose pre-edit the test sets, standing in for a dead key
 * or IBus mid-composition. */
class TestIM : Gtk.IMContext {
    public string preedit = "";

    public override void get_preedit_string (out string str, out Pango.AttrList attrs, out int cursor_pos) {
        str = preedit;
        attrs = new Pango.AttrList ();
        cursor_pos = preedit.char_count ();
    }

    public void set_preedit (string text) {
        preedit = text;
        preedit_changed ();
    }
}

static string esc (string s) {
    return "\x1b" + s;
}

static Gvt.Terminal terminal () {
    return TestUtil.new_terminal ();
}

static void test_plain () {
    var t = terminal ();
    var sent = new Sent (t.input);
    assert_true (t.input.key (GhosttyVt.Key.A, GhosttyVt.KeyAction.PRESS, 0, "a", 'a'));
    assert_cmpstr (sent.text (), CompareOperator.EQ, "a");
}

static void test_ctrl_c () {
    var t = terminal ();
    var sent = new Sent (t.input);
    assert_true (t.input.key (GhosttyVt.Key.C, GhosttyVt.KeyAction.PRESS, GhosttyVt.Mods.CTRL, "c", 'c'));
    assert_cmpstr (sent.text (), CompareOperator.EQ, "\x03");
}

static void test_app_cursor () {
    var t = terminal ();
    var sent = new Sent (t.input);
    t.input.key (GhosttyVt.Key.ARROW_UP, GhosttyVt.KeyAction.PRESS, 0, null, 0);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("[A"));
    sent.clear ();
    t.process_output (esc ("[?1h").data);
    t.input.key (GhosttyVt.Key.ARROW_UP, GhosttyVt.KeyAction.PRESS, 0, null, 0);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("OA"));
}

static void test_kitty () {
    var t = terminal ();
    var sent = new Sent (t.input);
    t.process_output (esc ("[>1u").data);
    t.input.key (GhosttyVt.Key.ESCAPE, GhosttyVt.KeyAction.PRESS, 0, null, 0);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("[27u"));
}

/* Review Focus 5: a dead key's pre-edit sends nothing, and the composed
 * character arrives as UTF-8. */
static void test_ime_commit () {
    var t = terminal ();
    var im = new TestIM ();
    t.input.im = im;
    var sent = new Sent (t.input);

    im.set_preedit ("´");
    assert_true (t.input.key (GhosttyVt.Key.E, GhosttyVt.KeyAction.PRESS, 0, "e", 'e'));
    assert_cmpuint (sent.bytes.len, CompareOperator.EQ, 0);
    t.input.key (GhosttyVt.Key.E, GhosttyVt.KeyAction.RELEASE, 0, "e", 'e');
    assert_cmpuint (sent.bytes.len, CompareOperator.EQ, 0);

    im.set_preedit ("");
    im.commit ("é");
    assert_cmpuint (sent.bytes.len, CompareOperator.EQ, 2);
    assert_cmpuint (sent.bytes.data[0], CompareOperator.EQ, 0xC3);
    assert_cmpuint (sent.bytes.data[1], CompareOperator.EQ, 0xA9);

    // With the composition over, keys reach the program again.
    sent.clear ();
    t.input.key (GhosttyVt.Key.A, GhosttyVt.KeyAction.PRESS, 0, "a", 'a');
    assert_cmpstr (sent.text (), CompareOperator.EQ, "a");
}

static void test_paste_bracketed () {
    var t = terminal ();
    var sent = new Sent (t.input);
    t.process_output (esc ("[?2004h").data);
    t.paste_text ("a" + esc ("[201~b"));
    var text = sent.text ();
    var start = esc ("[200~");
    var end = esc ("[201~");
    assert_true (text.has_prefix (start));
    assert_true (text.has_suffix (end));
    var payload = text.substring (start.length, text.length - start.length - end.length);
    assert_false (end in payload);
    assert_true (payload.has_prefix ("a"));
    assert_true (payload.has_suffix ("b"));
}

static void test_paste_plain () {
    var t = terminal ();
    var sent = new Sent (t.input);
    t.paste_text ("ls\n");
    assert_cmpstr (sent.text (), CompareOperator.EQ, "ls\r");
}

static void test_mouse_sgr () {
    var t = terminal ();
    var window = TestUtil.present (t);
    var sent = new Sent (t.input);
    int selections = 0;
    t.input.selection_event.connect (() => selections++);

    var cw = (double) t.get_char_width ();
    var ch = (double) t.get_char_height ();
    // Tracking off: the click is the selection's, not the program's.
    t.input.button (true, Gdk.BUTTON_PRIMARY, 2 * cw + cw / 2, 3 * ch + ch / 2, 0, 1);
    t.input.button (false, Gdk.BUTTON_PRIMARY, 2 * cw + cw / 2, 3 * ch + ch / 2, 0, 1);
    assert_cmpuint (sent.bytes.len, CompareOperator.EQ, 0);
    assert_cmpint (selections, CompareOperator.EQ, 2);

    selections = 0;
    t.process_output (esc ("[?1000h").data);
    t.process_output (esc ("[?1006h").data);
    t.input.button (true, Gdk.BUTTON_PRIMARY, 2 * cw + cw / 2, 3 * ch + ch / 2, 0, 1);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("[<0;3;4M"));
    assert_cmpint (selections, CompareOperator.EQ, 0);
    window.destroy ();
}

static void test_focus () {
    var t = terminal ();
    var sent = new Sent (t.input);
    t.input.focus_changed (false);
    assert_cmpuint (sent.bytes.len, CompareOperator.EQ, 0);
    t.process_output (esc ("[?1004h").data);
    t.input.focus_changed (false);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("[O"));
}

static void test_keymap () {
    assert_true (Gvt.Keymap.from_evdev (30) == GhosttyVt.Key.A);
    assert_true (Gvt.Keymap.from_evdev (1) == GhosttyVt.Key.ESCAPE);
    assert_true (Gvt.Keymap.from_evdev (103) == GhosttyVt.Key.ARROW_UP);
    assert_true (Gvt.Keymap.from_evdev (0) == GhosttyVt.Key.UNIDENTIFIED);
    assert_true (Gvt.Keymap.from_evdev (100000) == GhosttyVt.Key.UNIDENTIFIED);
}

public static int main (string[] args) {
    Test.init (ref args);
    Gtk.init ();
    Test.add_func ("/input/plain", test_plain);
    Test.add_func ("/input/ctrl-c", test_ctrl_c);
    Test.add_func ("/input/app-cursor", test_app_cursor);
    Test.add_func ("/input/kitty", test_kitty);
    Test.add_func ("/input/ime-commit", test_ime_commit);
    Test.add_func ("/input/paste-bracketed", test_paste_bracketed);
    Test.add_func ("/input/paste-plain", test_paste_plain);
    Test.add_func ("/input/mouse-sgr", test_mouse_sgr);
    Test.add_func ("/input/focus", test_focus);
    Test.add_func ("/input/keymap", test_keymap);
    return Test.run ();
}
