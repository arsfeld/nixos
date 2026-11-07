// Engine against known byte streams. Compiled together with src/Engine.vala,
// because Engine is internal to the library.

static Gvt.Engine make (uint16 cols = 80, uint16 rows = 24) {
    return new Gvt.Engine (cols, rows);
}

static void feed (Gvt.Engine engine, string s) {
    engine.write (s.data);
}

static string bytes_to_string (uint8[] bytes) {
    var b = new StringBuilder ();
    b.append_len ((string) bytes, bytes.length);
    return b.str;
}

static void test_text () {
    var engine = make ();
    feed (engine, "hello");
    assert_cmpstr (engine.text_range (0, 0, 0, 5), CompareOperator.EQ, "hello");
    long col, row;
    engine.cursor (out col, out row);
    assert_cmpint ((int) col, CompareOperator.EQ, 5);
    assert_cmpint ((int) row, CompareOperator.EQ, 0);
}

// NixOS's default bash PS1: bold green, with an OSC 0 title inside it.
const string NIXOS_PS1 = "\r\n\x1b[1;32m[\x1b]0;arosenfeld@machine: /home/arosenfeld\x07"
    + "arosenfeld@machine:/home/arosenfeld]$\x1b[0m ";

static void test_prompt_cursor () {
    var engine = make ();
    feed (engine, NIXOS_PS1);
    long col, row;
    engine.cursor (out col, out row);
    // "[arosenfeld@machine:/home/arosenfeld]$ " is 39 cells; the OSC is not.
    assert_cmpint ((int) col, CompareOperator.EQ, 39);
    assert_cmpint ((int) row, CompareOperator.EQ, 1);
    assert_cmpstr (engine.text_range (1, 0, 1, 39), CompareOperator.EQ,
                   "[arosenfeld@machine:/home/arosenfeld]$");
    assert_cmpstr (engine.title, CompareOperator.EQ, "arosenfeld@machine: /home/arosenfeld");
}

static void test_title () {
    var engine = make ();
    int fired = 0;
    engine.title_changed.connect (() => fired++);
    feed (engine, "\x1b]2;hi\x07");
    assert_cmpint (fired, CompareOperator.EQ, 1);
    assert_cmpstr (engine.title, CompareOperator.EQ, "hi");
}

static void test_pwd () {
    var engine = make ();
    int fired = 0;
    engine.pwd_changed.connect (() => fired++);
    feed (engine, "\x1b]7;file://host/tmp\x07");
    assert_cmpint (fired, CompareOperator.GE, 1);
    assert_cmpstr (engine.pwd, CompareOperator.EQ, "file://host/tmp");
}

static void test_bell () {
    var engine = make ();
    int fired = 0;
    engine.bell.connect (() => fired++);
    feed (engine, "\x07");
    assert_cmpint (fired, CompareOperator.EQ, 1);
}

static void test_osc52_write () {
    var engine = make ();
    string? got = null;
    engine.clipboard_write.connect ((text) => got = text);
    feed (engine, "\x1b]52;c;aGVsbG8=\x07");
    assert_cmpstr (got, CompareOperator.EQ, "hello");
}

static void test_osc52_read () {
    var engine = make ();
    int requested = 0;
    var replies = new StringBuilder ();
    engine.write_pty.connect ((bytes) => replies.append (bytes_to_string (bytes)));
    // libghostty's read is synchronous: the reply must come before the
    // handler returns.
    engine.clipboard_read_requested.connect ((granted, reply) => {
        requested++;
        reply ("x");
    });
    feed (engine, "\x1b]52;c;?\x07");
    assert_cmpint (requested, CompareOperator.EQ, 1);
    assert_true (replies.str.contains ("eA=="));
}

static void test_osc52_read_not_granted () {
    var engine = make ();
    bool? granted = null;
    engine.clipboard_read_requested.connect ((g, reply) => {
        granted = g;
        reply ("x");
    });
    feed (engine, "\x1b]52;c;?\x07");
    assert_true (granted != null);
    assert_false (granted);
}

/* A handler that drops the last reference must not free the terminal in
 * the middle of its own vt_write. */
static void test_drop_in_handler () {
    Gvt.Engine? engine = make ();
    bool finalized = false;
    engine.weak_ref (() => finalized = true);
    int titles = 0;
    engine.title_changed.connect (() => titles++);
    engine.bell.connect (() => engine = null);
    // Called on the captured variable, so the call itself holds no reference.
    // Vala hex escapes are greedy, hence the concatenation.
    engine.write (("\x07" + "after\x1b]2;t\x07more").data);
    assert_true (engine == null);
    assert_cmpint (titles, CompareOperator.EQ, 1);
    assert_true (finalized);
}

static void test_ris_clears_title () {
    var engine = make ();
    feed (engine, "\x1b]2;hi\x07\x1b]7;file://host/tmp\x07");
    int titles = 0, pwds = 0;
    engine.title_changed.connect (() => titles++);
    engine.pwd_changed.connect (() => pwds++);
    feed (engine, "\x1b" + "c"); // RIS
    assert_cmpint (titles, CompareOperator.EQ, 1);
    assert_cmpint (pwds, CompareOperator.EQ, 1);
    assert_true (engine.title == null);
    assert_true (engine.pwd == null);
}

static void test_reset_clears_title () {
    var engine = make ();
    feed (engine, "\x1b]2;hi\x07\x1b]7;file://host/tmp\x07");
    int titles = 0, pwds = 0;
    engine.title_changed.connect (() => titles++);
    engine.pwd_changed.connect (() => pwds++);
    engine.reset (true);
    assert_cmpint (titles, CompareOperator.EQ, 1);
    assert_cmpint (pwds, CompareOperator.EQ, 1);
    assert_true (engine.title == null);
    assert_true (engine.pwd == null);
}

static void test_da1 () {
    var engine = make ();
    var replies = new StringBuilder ();
    engine.write_pty.connect ((bytes) => replies.append (bytes_to_string (bytes)));
    feed (engine, "\x1b[c");
    assert_true (replies.str.has_prefix ("\x1b[?"));
}

static void test_scrollback () {
    var engine = make (80, 5);
    for (int i = 0; i < 10; i++) {
        feed (engine, "L%d\r\n".printf (i));
    }
    assert_cmpint ((int) engine.scrollback_rows, CompareOperator.GE, 5);
    long col, abs_row;
    engine.cursor (out col, out abs_row);
    // 10 lines on 5 rows leave the cursor on the last row of the screen.
    assert_cmpint ((int) abs_row, CompareOperator.EQ, (int) engine.scrollback_rows + 4);
    assert_cmpstr (engine.text_range (abs_row - 1, 0, abs_row - 1, 2), CompareOperator.EQ, "L9");
}

static void test_resize () {
    var engine = make ();
    engine.resize (40, 10, 8, 16);
    assert_cmpint (engine.cols, CompareOperator.EQ, 40);
    assert_cmpint (engine.rows, CompareOperator.EQ, 10);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/engine/text", test_text);
    Test.add_func ("/engine/title", test_title);
    Test.add_func ("/engine/prompt-cursor", test_prompt_cursor);
    Test.add_func ("/engine/pwd", test_pwd);
    Test.add_func ("/engine/bell", test_bell);
    Test.add_func ("/engine/osc52-write", test_osc52_write);
    Test.add_func ("/engine/osc52-read", test_osc52_read);
    Test.add_func ("/engine/osc52-read-not-granted", test_osc52_read_not_granted);
    Test.add_func ("/engine/drop-in-handler", test_drop_in_handler);
    Test.add_func ("/engine/ris-clears-title", test_ris_clears_title);
    Test.add_func ("/engine/reset-clears-title", test_reset_clears_title);
    Test.add_func ("/engine/da1", test_da1);
    Test.add_func ("/engine/scrollback", test_scrollback);
    Test.add_func ("/engine/resize", test_resize);
    return Test.run ();
}
