/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Unit tests for the stack config and data layer. Nothing here needs a display.
 */

using Dock;

void test_parse_expands_home () {
    try {
        var config = StackConfig.parse ("~/Downloads", "fan", "date-added", "stack");
        assert_cmpstr (config.source, EQ, Path.build_filename (Environment.get_home_dir (), "Downloads"));
        assert_true (config.view == StackConfig.View.FAN);
        assert_true (config.sort == StackConfig.Sort.DATE_ADDED);
        assert_true (config.display == StackConfig.Display.STACK);
        assert_false (config.is_applications);
    } catch (StackConfigError e) {
        error ("unexpected error: %s", e.message);
    }
}

void test_parse_applications () {
    try {
        var config = StackConfig.parse ("applications", "grid", "name", "folder");
        assert_cmpstr (config.source, EQ, "applications");
        assert_true (config.is_applications);
        assert_true (config.view == StackConfig.View.GRID);
        assert_true (config.sort == StackConfig.Sort.NAME);
        assert_true (config.display == StackConfig.Display.FOLDER);
    } catch (StackConfigError e) {
        error ("unexpected error: %s", e.message);
    }
}

void assert_rejected (string source, string view, string sort, string display) {
    try {
        StackConfig.parse (source, view, sort, display);
        error ("accepted (%s, %s, %s, %s)", source, view, sort, display);
    } catch (StackConfigError e) {
        // expected
    }
}

void test_parse_rejects_invalid () {
    assert_rejected ("Downloads", "fan", "name", "stack");          // relative path
    assert_rejected ("/tmp", "spiral", "name", "stack");            // unknown view
    assert_rejected ("/tmp", "fan", "size", "stack");               // unknown sort
    assert_rejected ("/tmp", "fan", "name", "pile");                // unknown display
}

void test_parse_all_skips_invalid () {
    var stacks = new Variant.parsed ("[('/tmp', 'fan', 'name', 'stack'), ('/tmp', 'spiral', 'name', 'stack'), ('applications', 'grid', 'name', 'stack')]");
    // The dock sets no G_LOG_DOMAIN, so warnings carry a null domain, and
    // valac prefixes the message with file:line, hence the leading wildcard.
    Test.expect_message (null, LogLevelFlags.LEVEL_WARNING, "*Ignoring stack /tmp: *");
    var configs = StackConfig.parse_all (stacks);
    Test.assert_expected_messages ();
    assert_cmpuint (configs.length, EQ, 2);
    assert_cmpstr (configs[0].source, EQ, "/tmp");
    assert_true (configs[1].is_applications);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/stack-config/expands-home", test_parse_expands_home);
    Test.add_func ("/stack-config/applications", test_parse_applications);
    Test.add_func ("/stack-config/rejects-invalid", test_parse_rejects_invalid);
    Test.add_func ("/stack-config/parse-all-skips-invalid", test_parse_all_skips_invalid);
    return Test.run ();
}
