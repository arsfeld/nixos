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

string[] entry_names (StackSource source) {
    string[] names = {};
    for (uint i = 0; i < source.entries.get_n_items (); i++) {
        names += ((StackEntry) source.entries.get_item (i)).name;
    }
    return names;
}

void wait_for_load (StackSource source) {
    var loop = new MainLoop ();
    var handler = source.loaded.connect (() => loop.quit ());
    var timeout_id = Timeout.add_seconds (5, () => {
        error ("timed out waiting for StackSource.loaded");
    });
    loop.run ();
    Source.remove (timeout_id);
    source.disconnect (handler);
}

string make_folder () {
    try {
        var dir = DirUtils.make_tmp ("stacks-XXXXXX");
        // alpha.pdf is created first, so it is older but sorts first by name.
        FileUtils.set_contents (Path.build_filename (dir, "alpha.pdf"), "x");
        Thread.usleep (50000);
        FileUtils.set_contents (Path.build_filename (dir, "zeta.zip"), "x");
        FileUtils.set_contents (Path.build_filename (dir, ".hidden"), "x");
        FileUtils.set_contents (Path.build_filename (dir, "big.iso.part"), "x");
        FileUtils.set_contents (Path.build_filename (dir, "video.mp4.crdownload"), "x");
        FileUtils.set_contents (Path.build_filename (dir, "safari.download"), "x");
        return dir;
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}

void test_shown_names () {
    assert_true (StackSource.is_shown_name ("report.pdf"));
    assert_false (StackSource.is_shown_name (".hidden"));
    assert_false (StackSource.is_shown_name ("a.part"));
    assert_false (StackSource.is_shown_name ("a.crdownload"));
    assert_false (StackSource.is_shown_name ("a.download"));
}

void test_folder_date_added () {
    var source = new StackSource (new StackConfig (make_folder (), FAN, DATE_ADDED, STACK));
    wait_for_load (source);
    assert_false (source.missing);
    assert_true (strv_equal (entry_names (source), { "zeta.zip", "alpha.pdf" }));
}

void test_folder_name () {
    var source = new StackSource (new StackConfig (make_folder (), GRID, NAME, STACK));
    wait_for_load (source);
    assert_true (strv_equal (entry_names (source), { "alpha.pdf", "zeta.zip" }));
}

void test_folder_live_update () {
    var dir = make_folder ();
    var source = new StackSource (new StackConfig (dir, FAN, DATE_ADDED, STACK));
    wait_for_load (source);
    Thread.usleep (50000);
    try {
        FileUtils.set_contents (Path.build_filename (dir, "newest.txt"), "x");
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
    wait_for_load (source);
    assert_true (strv_equal (entry_names (source), { "newest.txt", "zeta.zip", "alpha.pdf" }));
}

void test_folder_missing () {
    var source = new StackSource (new StackConfig ("/nonexistent/stacks-test", FAN, DATE_ADDED, STACK));
    wait_for_load (source);
    assert_true (source.missing);
    assert_cmpuint (source.entries.get_n_items (), EQ, 0);
}

void test_applications () {
    var source = new StackSource (new StackConfig (StackConfig.APPLICATIONS, GRID, NAME, STACK));
    wait_for_load (source);
    // Case-insensitive A–Z; the NoDisplay entry is left out.
    assert_true (strv_equal (entry_names (source), { "alpha", "Beta" }));
}

void write_desktop_files (string data_dir) {
    var apps = Path.build_filename (data_dir, "applications");
    DirUtils.create_with_parents (apps, 0755);
    try {
        FileUtils.set_contents (Path.build_filename (apps, "b.desktop"), "[Desktop Entry]\nType=Application\nName=Beta\nExec=true\n");
        FileUtils.set_contents (Path.build_filename (apps, "a.desktop"), "[Desktop Entry]\nType=Application\nName=alpha\nExec=true\n");
        FileUtils.set_contents (Path.build_filename (apps, "hidden.desktop"), "[Desktop Entry]\nType=Application\nName=Hidden\nExec=true\nNoDisplay=true\n");
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}

int main (string[] args) {
    // AppInfo reads these once, on first use: point it at fixture apps only.
    try {
        var data_dir = DirUtils.make_tmp ("stacks-apps-XXXXXX");
        write_desktop_files (data_dir);
        Environment.set_variable ("XDG_DATA_DIRS", data_dir, true);
        Environment.set_variable ("XDG_DATA_HOME", DirUtils.make_tmp ("stacks-home-XXXXXX"), true);
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }

    Test.init (ref args);
    Test.add_func ("/stack-config/expands-home", test_parse_expands_home);
    Test.add_func ("/stack-config/applications", test_parse_applications);
    Test.add_func ("/stack-config/rejects-invalid", test_parse_rejects_invalid);
    Test.add_func ("/stack-config/parse-all-skips-invalid", test_parse_all_skips_invalid);
    Test.add_func ("/stack-source/shown-names", test_shown_names);
    Test.add_func ("/stack-source/folder-date-added", test_folder_date_added);
    Test.add_func ("/stack-source/folder-name", test_folder_name);
    Test.add_func ("/stack-source/folder-live-update", test_folder_live_update);
    Test.add_func ("/stack-source/folder-missing", test_folder_missing);
    Test.add_func ("/stack-source/applications", test_applications);
    return Test.run ();
}
