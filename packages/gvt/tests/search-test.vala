// The find bar (search_set_regex, search_find_next/previous: literal,
// case-insensitive, scrollback included) and URL matching (match_add_regex,
// check_match_at), with VTE's names, as elementary calls them.

/* A terminal allocated to cols x rows cells, not in a window. */
static Gvt.Terminal sized (int cols, int rows) {
    var t = TestUtil.new_terminal ();
    TestUtil.measure (t);
    var cw = (int) t.get_char_width ();
    var ch = (int) t.get_char_height ();
    t.allocate (cols * cw, rows * ch, -1, null);
    assert_cmpuint (t.engine.rows, CompareOperator.EQ, rows);
    return t;
}

/* "alpha" twice, in two cases, around a line without it. */
static Gvt.Terminal alphas () {
    var t = TestUtil.new_terminal ();
    t.process_output ("alpha\r\nbeta\r\nALPHA".data);
    try {
        t.search_set_regex (new Gvt.Regex.for_search ("alpha", -1, 0), 0);
    } catch (Error e) {
        assert_no_error (e);
    }
    return t;
}

static void test_next () {
    var t = alphas ();
    // From the top, downwards; the second hit only matches without case.
    assert_true (t.search_find_next ());
    assert_cmpstr (t.engine.selection_text (), CompareOperator.EQ, "alpha");
    assert_true (t.search_find_next ());
    assert_cmpstr (t.engine.selection_text (), CompareOperator.EQ, "ALPHA");
    // Wrap-around is off by default: the end is the end.
    assert_false (t.search_find_next ());
    assert_cmpstr (t.engine.selection_text (), CompareOperator.EQ, "ALPHA");
}

static void test_wrap () {
    var t = alphas ();
    t.search_set_wrap_around (true);
    assert_true (t.search_find_next ());
    assert_true (t.search_find_next ());
    assert_true (t.search_find_next ());
    assert_cmpstr (t.engine.selection_text (), CompareOperator.EQ, "alpha");
}

static void test_previous () {
    var t = alphas ();
    t.search_set_wrap_around (true);
    // Nothing selected yet: upwards from the bottom, so the last hit.
    assert_true (t.search_find_previous ());
    assert_cmpstr (t.engine.selection_text (), CompareOperator.EQ, "ALPHA");
    assert_true (t.get_has_selection ());
}

static void test_scrollback () {
    var t = sized (20, 5);
    var output = new StringBuilder ("needle\r\n");
    for (var i = 0; i < 20; i++) {
        output.append ("line %d\r\n".printf (i));
    }
    t.process_output (output.str.data);
    assert_true (TestUtil.wait_until (() => t.vadjustment.value > 0, 5));
    try {
        t.search_set_regex (new Gvt.Regex.for_search ("needle", -1, 0), 0);
    } catch (Error e) {
        assert_no_error (e);
    }
    assert_true (t.search_find_next ());
    assert_cmpstr (t.engine.selection_text (), CompareOperator.EQ, "needle");
    // The match, on row 0, was scrolled into view.
    assert_cmpfloat (t.vadjustment.value, CompareOperator.EQ, 0);
    assert_cmpint ((int) t.engine.viewport_top, CompareOperator.EQ, 0);
}

static void test_url () {
    var t = TestUtil.new_terminal ();
    int tag = -1;
    try {
        tag = t.match_add_regex (new Gvt.Regex.for_match ("https?://[^ ]+", -1, 0), 0);
    } catch (Error e) {
        assert_no_error (e);
    }
    t.match_set_cursor_name (tag, "pointer");
    t.process_output ("see https://x.org now".data);
    var cw = t.get_char_width ();
    var ch = t.get_char_height ();

    int found = -1;
    assert_cmpstr (t.check_match_at (8 * cw + cw / 2, ch / 2, out found), CompareOperator.EQ, "https://x.org");
    assert_cmpint (found, CompareOperator.EQ, tag);
    assert_null (t.check_match_at (1 * cw + cw / 2, ch / 2, out found));
    assert_cmpint (found, CompareOperator.EQ, -1);
    // elementary's get_link passes null for the tag.
    assert_cmpstr (t.check_match_at (8 * cw + cw / 2, ch / 2, null), CompareOperator.EQ, "https://x.org");

    // Hovering a match shows its tag's cursor; leaving it, the default.
    t.matcher.hover (8 * cw + cw / 2, ch / 2);
    assert_nonnull (t.get_cursor ());
    assert_cmpstr (t.get_cursor ().get_name (), CompareOperator.EQ, "pointer");
    t.matcher.hover (1 * cw + cw / 2, ch / 2);
    assert_null (t.get_cursor ());

    t.match_remove_all ();
    assert_null (t.check_match_at (8 * cw + cw / 2, ch / 2, null));
}

/* A URL longer than the terminal is wide soft-wraps, and is still one
 * match, from either of its rows. A hard line break still ends one. */
static void test_url_wrapped () {
    var t = TestUtil.new_terminal ();
    try {
        t.match_add_regex (new Gvt.Regex.for_match ("https?://[^ ]+", -1, 0), 0);
    } catch (Error e) {
        assert_no_error (e);
    }
    assert_cmpuint (t.engine.cols, CompareOperator.EQ, 80);
    var url = "https://example.org/" + string.nfill (100, 'a');
    t.process_output (("see " + url + " now\r\nhttps://y.org").data);
    var cw = t.get_char_width ();
    var ch = t.get_char_height ();
    assert_cmpstr (t.check_match_at (10 * cw + cw / 2, ch / 2, null), CompareOperator.EQ, url);
    assert_cmpstr (t.check_match_at (5 * cw + cw / 2, ch + ch / 2, null), CompareOperator.EQ, url);
    assert_cmpstr (t.check_match_at (2 * cw + cw / 2, 2 * ch + ch / 2, null), CompareOperator.EQ, "https://y.org");
    assert_null (t.check_match_at (46 * cw + cw / 2, ch + ch / 2, null));
}

static void test_bad_regex () {
    try {
        new Gvt.Regex.for_match ("(", -1, 0);
        assert_not_reached ();
    } catch (Error e) {
        assert_true (e is RegexError);
    }
}

public static int main (string[] args) {
    Test.init (ref args);
    Gtk.init ();
    Test.add_func ("/search/next", test_next);
    Test.add_func ("/search/wrap", test_wrap);
    Test.add_func ("/search/previous", test_previous);
    Test.add_func ("/search/scrollback", test_scrollback);
    Test.add_func ("/match/url", test_url);
    Test.add_func ("/match/bad-regex", test_bad_regex);
    Test.add_func ("/match/url-wrapped", test_url_wrapped);
    return Test.run ();
}
