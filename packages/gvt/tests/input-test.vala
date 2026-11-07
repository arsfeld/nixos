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

/* GtkIMContextSimple after a dead key, on a key it does not compose with:
 * commits the spacing accent and lets the key itself through. */
class DeadKeyIM : Gtk.IMContext, Gvt.KeyFilter {
    public int filtered = 0;

    public override bool filter_keypress (Gdk.Event event) {
        filtered++;
        commit ("´");
        return false;
    }

    /* The same, for a key given by its fields (see Gvt.KeyFilter). */
    public bool filter_key_fields (uint keyval, uint keycode, Gdk.ModifierType state) {
        filtered++;
        commit ("´");
        return false;
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

/* Review Focus 5: ´ then Enter reaches the shell as "´\r", through the
 * real key-press path (the IM filters first). */
static void test_dead_key_then_enter () {
    var t = terminal ();
    var window = TestUtil.present (t);
    var im = new DeadKeyIM ();
    t.input.im = im;
    var sent = new Sent (t.input);
    // Enter: evdev 28, GDK hardware keycode 36.
    assert_true (t.input.key_press (null, Gdk.Key.Return, 36, 0));
    assert_cmpint (im.filtered, CompareOperator.EQ, 1);
    assert_cmpuint (sent.bytes.len, CompareOperator.EQ, 3);
    assert_cmpuint (sent.bytes.data[0], CompareOperator.EQ, 0xC2);
    assert_cmpuint (sent.bytes.data[1], CompareOperator.EQ, 0xB4);
    assert_cmpuint (sent.bytes.data[2], CompareOperator.EQ, '\r');
    window.destroy ();
}

static void test_alt_scroll () {
    var t = terminal ();
    var sent = new Sent (t.input);
    t.process_output (esc ("[?1049h").data);
    assert_true (t.input.scroll (1, false));
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("[B") + esc ("[B") + esc ("[B"));
    sent.clear ();
    t.process_output (esc ("[?1h").data);
    t.input.scroll (1, false);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("OB") + esc ("OB") + esc ("OB"));
    sent.clear ();
    t.input.scroll (-1, false);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("OA") + esc ("OA") + esc ("OA"));
    // Smooth deltas accumulate into whole lines (one line = one cell height).
    sent.clear ();
    var ch = (double) t.get_char_height ();
    t.input.scroll (ch * 0.6, true);
    assert_cmpuint (sent.bytes.len, CompareOperator.EQ, 0);
    t.input.scroll (ch * 0.6, true);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("OB"));
}

static void test_primary_scroll () {
    var t = terminal ();
    var sent = new Sent (t.input);
    var lines = new StringBuilder ();
    for (var i = 0; i < 100; i++) {
        lines.append ("line %d\r\n".printf (i));
    }
    t.process_output (lines.str.data);
    assert_true (TestUtil.wait_until (() => t.vadjustment.upper > 100));
    var bottom = t.vadjustment.value;
    assert_true (t.input.scroll (-1, false));
    assert_true (t.vadjustment.value < bottom);
    assert_true (t.engine.viewport_top < (long) bottom);
    assert_cmpuint (sent.bytes.len, CompareOperator.EQ, 0);
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

/* A touchpad (pixel) scroll moves the view by the rows it covers. The
 * tenth-of-a-page step is the wheel's: on a 50-row window a three-row swipe
 * scrolled fifteen. */
static void test_pixel_scroll () {
    var t = terminal ();
    t.set_size_request ((int) t.get_char_width () * 80, (int) t.get_char_height () * 50);
    var window = TestUtil.present (t);
    var lines = new StringBuilder ();
    for (var i = 0; i < 200; i++) {
        lines.append ("line %d\r\n".printf (i));
    }
    t.process_output (lines.str.data);
    assert_true (TestUtil.wait_until (() => t.vadjustment.upper > 200));
    assert_cmpfloat (t.vadjustment.page_size, CompareOperator.EQ, 50);
    var bottom = t.vadjustment.value;
    var ch = (double) t.get_char_height ();
    assert_true (t.input.scroll (-3 * ch, true));
    assert_cmpfloat (t.vadjustment.value, CompareOperator.EQ, bottom - 3);
    // The wheel keeps VTE's step: a tenth of the page a notch.
    t.input.scroll (-1, false);
    assert_cmpfloat (t.vadjustment.value, CompareOperator.EQ, bottom - 3 - 5);
    window.destroy ();
}

/* Shift bypasses mouse tracking, as in VTE, xterm and Ghostty: Shift+drag
 * selects even under a program that tracks the mouse. */
static void test_shift_bypasses_tracking () {
    var t = terminal ();
    var window = TestUtil.present (t);
    var sent = new Sent (t.input);
    var phases = new GenericArray<Gvt.PointerPhase> ();
    t.input.selection_event.connect ((phase) => phases.add (phase));
    t.process_output (esc ("[?1000h").data);
    t.process_output (esc ("[?1006h").data);

    var cw = (double) t.get_char_width ();
    var ch = (double) t.get_char_height ();
    var shift = Gdk.ModifierType.SHIFT_MASK;
    t.input.button (true, Gdk.BUTTON_PRIMARY, cw / 2, ch / 2, shift, 1);
    t.input.motion (5 * cw + cw / 2, ch / 2, shift | Gdk.ModifierType.BUTTON1_MASK);
    t.input.button (false, Gdk.BUTTON_PRIMARY, 5 * cw + cw / 2, ch / 2,
                    shift | Gdk.ModifierType.BUTTON1_MASK, 1);
    assert_cmpuint (sent.bytes.len, CompareOperator.EQ, 0);
    assert_cmpint (phases.length, CompareOperator.EQ, 3);
    assert_true (phases[0] == Gvt.PointerPhase.PRESS);
    assert_true (phases[1] == Gvt.PointerPhase.DRAG);
    assert_true (phases[2] == Gvt.PointerPhase.RELEASE);
    assert_true (t.get_has_selection ());

    // Without Shift the program still gets the click.
    t.input.button (true, Gdk.BUTTON_PRIMARY, cw / 2, ch / 2, 0, 1);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("[<0;1;1M"));
    window.destroy ();
}

/* A press whose release never arrives (elementary's right-click handler
 * claims the sequence and opens a popover, which cancels gvt's gestures)
 * does not leave the button held: the next click is routed afresh. */
static void test_cancelled_press () {
    var t = terminal ();
    var window = TestUtil.present (t);
    var sent = new Sent (t.input);
    var cw = (double) t.get_char_width ();
    var ch = (double) t.get_char_height ();

    t.input.button (true, Gdk.BUTTON_SECONDARY, cw / 2, ch / 2, 0, 1);
    // GTK cancels the drag gesture, whose current button is then 0.
    Gtk.GestureDrag? drag = null;
    var controllers = t.observe_controllers ();
    for (uint i = 0; i < controllers.get_n_items (); i++) {
        var c = controllers.get_item (i) as Gtk.GestureDrag;
        if (c != null) {
            drag = c;
        }
    }
    assert_nonnull (drag);
    assert_true (t.input.pointer_held);
    Signal.emit_by_name (drag, "cancel", null);
    assert_false (t.input.pointer_held);

    t.process_output (esc ("[?1000h").data);
    t.process_output (esc ("[?1006h").data);
    t.input.button (true, Gdk.BUTTON_PRIMARY, cw / 2, ch / 2, 0, 1);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("[<0;1;1M"));
    window.destroy ();
}

/* A held bit no button state backs (a release lost some other way) is
 * dropped at the next press: GDK's state lists the buttons down before it. */
static void test_stale_button_dropped () {
    var t = terminal ();
    var window = TestUtil.present (t);
    var sent = new Sent (t.input);
    var cw = (double) t.get_char_width ();
    var ch = (double) t.get_char_height ();

    t.input.button (true, Gdk.BUTTON_SECONDARY, cw / 2, ch / 2, 0, 1);
    t.process_output (esc ("[?1000h").data);
    t.process_output (esc ("[?1006h").data);
    t.input.button (true, Gdk.BUTTON_PRIMARY, cw / 2, ch / 2, 0, 1);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("[<0;1;1M"));
    window.destroy ();
}

/* Keys held when focus goes are forgotten: their releases go to some other
 * window, and the next press is a press, not a Kitty repeat. */
static void test_focus_out_forgets_keys () {
    var t = terminal ();
    var sent = new Sent (t.input);
    // Disambiguate + report event types.
    t.process_output (esc ("[>3u").data);
    // Escape: GDK hardware keycode 9.
    t.input.key_press (null, Gdk.Key.Escape, 9, 0);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("[27u"));
    sent.clear ();
    t.input.focus_changed (false);
    t.input.focus_changed (true);
    t.input.key_press (null, Gdk.Key.Escape, 9, 0);
    assert_cmpstr (sent.text (), CompareOperator.EQ, esc ("[27u"));
}

public static int main (string[] args) {
    Test.init (ref args);
    Gtk.init ();
    Test.add_func ("/input/plain", test_plain);
    Test.add_func ("/input/ctrl-c", test_ctrl_c);
    Test.add_func ("/input/app-cursor", test_app_cursor);
    Test.add_func ("/input/kitty", test_kitty);
    Test.add_func ("/input/ime-commit", test_ime_commit);
    Test.add_func ("/input/dead-key-then-enter", test_dead_key_then_enter);
    Test.add_func ("/input/alt-scroll", test_alt_scroll);
    Test.add_func ("/input/primary-scroll", test_primary_scroll);
    Test.add_func ("/input/paste-bracketed", test_paste_bracketed);
    Test.add_func ("/input/paste-plain", test_paste_plain);
    Test.add_func ("/input/mouse-sgr", test_mouse_sgr);
    Test.add_func ("/input/focus", test_focus);
    Test.add_func ("/input/keymap", test_keymap);
    Test.add_func ("/input/pixel-scroll", test_pixel_scroll);
    Test.add_func ("/input/shift-bypasses-tracking", test_shift_bypasses_tracking);
    Test.add_func ("/input/cancelled-press", test_cancelled_press);
    Test.add_func ("/input/stale-button-dropped", test_stale_button_dropped);
    Test.add_func ("/input/focus-out-forgets-keys", test_focus_out_forgets_keys);
    return Test.run ();
}
