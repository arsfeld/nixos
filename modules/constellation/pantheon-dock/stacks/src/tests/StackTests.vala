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

void test_parse_display_grid () {
    try {
        var config = StackConfig.parse ("applications", "grid", "name", "grid");
        assert_true (config.display == StackConfig.Display.GRID);
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

string[] model_names (ListModel model) {
    string[] names = {};
    for (uint i = 0; i < model.get_n_items (); i++) {
        names += ((StackEntry) model.get_item (i)).name;
    }
    return names;
}

StackEntry? find_entry (ListModel model, string name) {
    for (uint i = 0; i < model.get_n_items (); i++) {
        var entry = (StackEntry) model.get_item (i);
        if (entry.name == name) {
            return entry;
        }
    }
    return null;
}

void assert_near (double actual, double expected) {
    if ((actual - expected).abs () > 1e-9) {
        error ("%g != %g", actual, expected);
    }
}

void test_launcher_progress () {
    var progress = new LauncherProgress ();
    assert_true (LauncherProgress.is_browser ("web.desktop"));
    assert_false (LauncherProgress.is_browser ("a.desktop"));
    assert_false (LauncherProgress.is_browser ("missing.desktop"));

    assert_true (progress.download_fraction () < 0);
    progress.handle_update (new Variant.parsed ("('application://web.desktop', {'progress': <0.25>, 'progress-visible': <true>})"));
    assert_near (progress.download_fraction (), 0.25);
    // Not a browser: ignored.
    progress.update ("a.desktop", 0.9, true);
    assert_near (progress.download_fraction (), 0.25);
    // A partial update keeps the other key.
    progress.update ("web.desktop", 0.5, null);
    assert_near (progress.download_fraction (), 0.5);
    progress.update ("web.desktop", null, false);
    assert_true (progress.download_fraction () < 0);
    // Malformed: ignored without a crash.
    progress.handle_update (new Variant.parsed ("('nope',)"));
}

void test_downloads_tile () {
    try {
        var dir = DirUtils.make_tmp ("stacks-XXXXXX");
        make_file (dir, "done.zip");
        var source = new StackSource (new StackConfig (dir, FAN, DATE_ADDED, STACK));
        wait_for_load (source);
        assert_false (source.tile_busy);

        make_file (dir, "video.mp4.crdownload");
        wait_for_load (source);
        assert_true (source.tile_busy);
        assert_true (source.tile_progress < 0);

        // Chromium's LauncherEntry fraction, only because a .crdownload is present.
        LauncherProgress.get_default ().update ("web.desktop", 0.5, true);
        assert_near (source.tile_progress, 0.5);
        LauncherProgress.get_default ().update ("web.desktop", null, false);
        assert_true (source.tile_progress < 0);

        // A stalled download is not busy.
        var old = get_real_time () / 1000000 - 120;
        File.new_for_path (Path.build_filename (dir, "stale.iso.part")).replace_contents ("x".data, null, false, NONE, null);
        File.new_for_path (Path.build_filename (dir, "stale.iso.part")).set_attribute_uint64 (FileAttribute.TIME_MODIFIED, old, NONE);
        FileUtils.remove (Path.build_filename (dir, "video.mp4.crdownload"));
        wait_for_load (source);
        assert_false (source.tile_busy);
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
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

void make_file (string dir, string name, string contents = "x") {
    try {
        FileUtils.set_contents (Path.build_filename (dir, name), contents);
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
    Thread.usleep (20000);
}

string make_folder () {
    try {
        var dir = DirUtils.make_tmp ("stacks-XXXXXX");
        // alpha.pdf is created first, so it is older but sorts first by name.
        make_file (dir, "alpha.pdf");
        make_file (dir, "zeta.zip");
        make_file (dir, ".hidden");
        make_file (dir, "big.iso.part");
        make_file (dir, "video.mp4.crdownload");
        make_file (dir, "safari.download");
        return dir;
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}

void test_shown_names () {
    assert_true (StackSource.is_shown_name ("report.pdf"));
    assert_true (StackSource.is_shown_name ("a.part"));
    assert_false (StackSource.is_shown_name (".hidden"));
    assert_cmpstr (StackSource.download_suffix ("a.part"), EQ, ".part");
    assert_cmpstr (StackSource.download_suffix ("a.crdownload"), EQ, ".crdownload");
    assert_cmpstr (StackSource.download_suffix ("a.download"), EQ, ".download");
    assert_null (StackSource.download_suffix ("a.pdf"));
}

void test_folder_date_added () {
    var source = new StackSource (new StackConfig (make_folder (), FAN, DATE_ADDED, STACK));
    wait_for_load (source);
    assert_false (source.missing);
    assert_true (strv_equal (entry_names (source), { "safari", "video.mp4", "big.iso", "zeta.zip", "alpha.pdf" }));
    var video = (StackEntry) source.entries.get_item (1);
    assert_true (video.downloading);
    assert_true (video.status_text.has_prefix ("Downloading · "));
    assert_true (video.show_progress);
    assert_false (((StackEntry) source.entries.get_item (3)).downloading);
}

void test_folder_name () {
    var source = new StackSource (new StackConfig (make_folder (), GRID, NAME, STACK));
    wait_for_load (source);
    assert_true (strv_equal (entry_names (source), { "alpha.pdf", "big.iso", "safari", "video.mp4", "zeta.zip" }));
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
    assert_true (strv_equal (entry_names (source), { "newest.txt", "safari", "video.mp4", "big.iso", "zeta.zip", "alpha.pdf" }));
}

void test_firefox_placeholder_hidden () {
    try {
        var dir = DirUtils.make_tmp ("stacks-XXXXXX");
        make_file (dir, "empty.txt", "");          // a 0-byte file on its own stays
        make_file (dir, "movie.mkv", "");          // Firefox's placeholder…
        make_file (dir, "movie.mkv.part", "abc");  // …for this download
        var source = new StackSource (new StackConfig (dir, FAN, NAME, STACK));
        wait_for_load (source);
        assert_true (strv_equal (entry_names (source), { "empty.txt", "movie.mkv" }));
        var movie = (StackEntry) source.entries.get_item (1);
        assert_true (movie.downloading);
        assert_cmpuint ((uint) movie.bytes, EQ, 3);
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}

void test_download_stall () {
    var entry = new StackEntry ("x.iso", new ThemedIcon ("text-x-generic"), null, null, 0);
    var now = get_real_time ();
    entry.update_download (1024, now - StackEntry.STALL_USEC - 1000000, now);
    assert_true (entry.stalled);
    assert_false (entry.show_progress);
    assert_cmpstr (entry.status_text, EQ, "Stalled · " + format_size (1024));

    entry.update_download (2048, now, now);
    assert_false (entry.stalled);
    assert_true (entry.show_progress);
    assert_cmpstr (entry.status_text, EQ, "Downloading · " + format_size (2048));
}

void test_folder_missing () {
    var source = new StackSource (new StackConfig ("/nonexistent/stacks-test", FAN, DATE_ADDED, STACK));
    wait_for_load (source);
    assert_true (source.missing);
    assert_cmpuint (source.entries.get_n_items (), EQ, 0);
}

void test_folder_source_finalized () {
    bool finalized = false;
    StackSource? source = new StackSource (new StackConfig (make_folder (), FAN, DATE_ADDED, STACK));
    source.weak_ref (() => { finalized = true; });
    wait_for_load (source);
    source = null;
    assert_true (finalized);
}

void test_applications () {
    var source = new StackSource (new StackConfig (StackConfig.APPLICATIONS, GRID, NAME, STACK));
    wait_for_load (source);
    // Everyday apps A–Z, then the non-empty folders in fixed order; NoDisplay left out.
    assert_true (strv_equal (entry_names (source), {
        "alpha", "Beta", "Notes", "Web", "Games", "System", "Utilities", "Terminal Tools"
    }));
    assert_true (strv_equal (model_names (source.previews), { "alpha", "Beta", "Notes", "Web" }));

    var utilities = find_entry (source.entries, "Utilities");
    assert_true (utilities.is_folder);
    assert_true (strv_equal (model_names (utilities.children), { "Calc" }));
    assert_true (strv_equal (model_names (find_entry (source.entries, "System").children), { "Settings" }));
    assert_true (strv_equal (model_names (find_entry (source.entries, "Terminal Tools").children), { "Htop" }));
    assert_true (strv_equal (model_names (find_entry (source.entries, "Games").children), { "Gamma" }));
}

void test_applications_fan_flat () {
    var source = new StackSource (new StackConfig (StackConfig.APPLICATIONS, FAN, NAME, STACK));
    wait_for_load (source);
    assert_true (strv_equal (entry_names (source), {
        "alpha", "Beta", "Calc", "Gamma", "Htop", "Notes", "Settings", "Web"
    }));
    assert_true (strv_equal (model_names (source.previews), entry_names (source)));
}

void write_desktop_file (string apps, string id, string body) {
    try {
        FileUtils.set_contents (Path.build_filename (apps, id), "[Desktop Entry]\nType=Application\nExec=true\n" + body);
    } catch (Error e) {
        error ("fixture: %s", e.message);
    }
}

void write_desktop_files (string data_dir) {
    var apps = Path.build_filename (data_dir, "applications");
    DirUtils.create_with_parents (apps, 0755);
    write_desktop_file (apps, "b.desktop", "Name=Beta\n");
    write_desktop_file (apps, "a.desktop", "Name=alpha\n");
    write_desktop_file (apps, "hidden.desktop", "Name=Hidden\nNoDisplay=true\n");
    write_desktop_file (apps, "web.desktop", "Name=Web\nCategories=Network;WebBrowser;\nMimeType=text/html;x-scheme-handler/https;\n");
    write_desktop_file (apps, "game.desktop", "Name=Gamma\nCategories=Game;\n");
    write_desktop_file (apps, "settings.desktop", "Name=Settings\nCategories=Settings;\n");
    write_desktop_file (apps, "calc.desktop", "Name=Calc\nCategories=Utility;\n");
    write_desktop_file (apps, "notes.desktop", "Name=Notes\nCategories=Utility;Office;\n");
    write_desktop_file (apps, "htop.desktop", "Name=Htop\nTerminal=true\nCategories=System;Monitor;\n");
}

void test_fan_pose_open () {
    // The ends of the curve are the ones the fan was tuned to on screen.
    assert_near (FanMath.drift (0), 0);
    assert_near (FanMath.degrees (0), 0);
    assert_near (FanMath.drift (FanMath.MAX_ITEMS), 44);
    assert_near (FanMath.degrees (FanMath.MAX_ITEMS), 5);

    for (uint i = 0; i <= FanMath.MAX_ITEMS; i++) {
        foreach (var clicked in new bool[] { false, true }) {
            var pose = FanMath.pose (i, 0, clicked);
            assert_near (pose.x, FanMath.drift (i));
            assert_near (pose.y, -FanMath.ROW_HEIGHT * (i + 0.5));
            assert_near (pose.degrees, FanMath.degrees (i));
            assert_near (pose.alpha, 1);
        }
    }
}

void test_fan_pose_collapsed () {
    for (uint i = 0; i <= FanMath.MAX_ITEMS; i++) {
        // Every other row has folded into row 0's slot, upright and gone.
        var pose = FanMath.pose (i, 1, false);
        assert_near (pose.x, 0);
        assert_near (pose.y, -FanMath.ROW_HEIGHT * 0.5);
        assert_near (pose.degrees, 0);
        assert_near (pose.alpha, 0);

        // The clicked row stays where it was and fades.
        var clicked = FanMath.pose (i, 1, true);
        assert_near (clicked.x, FanMath.drift (i));
        assert_near (clicked.y, -FanMath.ROW_HEIGHT * (i + 0.5));
        assert_near (clicked.alpha, 0);
    }
    assert_near (FanMath.ghost_scale (0), 1);
    assert_near (FanMath.ghost_scale (1), 1.6);
}

void test_classify () {
    assert_true (AppFolders.classify ("Game;ActionGame;", false) == AppFolders.Folder.GAMES);
    assert_true (AppFolders.classify ("System;Monitor;", false) == AppFolders.Folder.SYSTEM);
    assert_true (AppFolders.classify ("Settings;", false) == AppFolders.Folder.SYSTEM);
    assert_true (AppFolders.classify ("Utility;", false) == AppFolders.Folder.UTILITIES);
    // A utility that is also an everyday app stays at the top level.
    assert_true (AppFolders.classify ("Utility;Office;", false) == AppFolders.Folder.NONE);
    assert_true (AppFolders.classify ("Network;WebBrowser;", false) == AppFolders.Folder.NONE);
    assert_true (AppFolders.classify (null, false) == AppFolders.Folder.NONE);
    // Terminal wins over everything else.
    assert_true (AppFolders.classify ("Game;", true) == AppFolders.Folder.TERMINAL);
    assert_cmpstr (AppFolders.Folder.TERMINAL.title (), EQ, "Terminal Tools");
}

AppCenterJobs.Job make_job (string desktop_id, AppCenterJobs.State state, double progress) {
    return new AppCenterJobs.Job ("comp." + desktop_id, desktop_id, "Newapp", "", state, progress);
}

void test_job_parsing () {
    var job = AppCenterJobs.Job.from_variant (new Variant.parsed ("('org.x', 'org.x.desktop', 'X', '', uint32 1, 0.5)"));
    assert_nonnull (job);
    assert_cmpstr (job.desktop_id, EQ, "org.x.desktop");
    assert_true (job.state == AppCenterJobs.State.INSTALLING);
    assert_cmpstr (job.status_text (), EQ, "Installing");

    Test.expect_message (null, LogLevelFlags.LEVEL_WARNING, "*Ignoring malformed AppCenter job*");
    assert_null (AppCenterJobs.Job.from_variant (new Variant.parsed ("('org.x',)")));
    Test.assert_expected_messages ();
}

void test_jobs_store () {
    var jobs = new AppCenterJobs ();
    jobs.apply (make_job ("a.desktop", UPDATING, 0.2));
    jobs.apply (make_job ("b.desktop", INSTALLING, 0.6));
    assert_cmpuint (jobs.count, EQ, 2);
    assert_near (jobs.mean_progress (), 0.4);
    jobs.apply (make_job ("a.desktop", IDLE, 1));
    assert_cmpuint (jobs.count, EQ, 1);
    assert_null (jobs.for_desktop_id ("a.desktop"));
    jobs.clear ();
    assert_cmpuint (jobs.count, EQ, 0);
}

void test_jobs_clear_keeps_fake () {
    var jobs = new AppCenterJobs ();
    jobs.apply (new AppCenterJobs.Job ("fake.x.desktop", "x.desktop", "X", "", INSTALLING, 0.5));
    jobs.apply (make_job ("real.desktop", UPDATING, 0.2));
    jobs.clear ();
    assert_cmpuint (jobs.count, EQ, 1);
    assert_nonnull (jobs.for_desktop_id ("x.desktop"));
    assert_null (jobs.for_desktop_id ("real.desktop"));
}

void test_applications_jobs () {
    var jobs = AppCenterJobs.get_default ();
    var source = new StackSource (new StackConfig (StackConfig.APPLICATIONS, GRID, NAME, STACK));
    wait_for_load (source);

    // A new install: a provisional cell first at the top level.
    jobs.apply (make_job ("new.desktop", INSTALLING, 0.3));
    wait_for_load (source);
    var first = (StackEntry) source.entries.get_item (0);
    assert_cmpstr (first.name, EQ, "Newapp");
    assert_cmpstr (first.status_text, EQ, "Installing");
    assert_near (first.progress, 0.3);
    assert_cmpstr (first.job_component_id, EQ, "comp.new.desktop");
    assert_true (source.tile_busy);
    assert_near (source.tile_progress, 0.3);

    // An update of an app inside a folder: the cell and the folder both show it.
    jobs.apply (make_job ("calc.desktop", UPDATING, 0.5));
    var utilities = find_entry (source.entries, "Utilities");
    var calc = find_entry (utilities.children, "Calc");
    assert_cmpstr (calc.status_text, EQ, "Updating");
    assert_true (utilities.show_progress);
    assert_near (utilities.progress, 0.5);
    assert_near (source.tile_progress, 0.4);

    jobs.apply (make_job ("calc.desktop", IDLE, 1));
    assert_null (calc.status_text);
    assert_null (calc.job_component_id);
    assert_false (utilities.show_progress);

    jobs.apply (make_job ("new.desktop", IDLE, 1));
    wait_for_load (source);
    assert_null (find_entry (source.entries, "Newapp"));
    assert_false (source.tile_busy);
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
    Test.add_func ("/stack-config/display-grid", test_parse_display_grid);
    Test.add_func ("/stack-config/rejects-invalid", test_parse_rejects_invalid);
    Test.add_func ("/stack-config/parse-all-skips-invalid", test_parse_all_skips_invalid);
    Test.add_func ("/stack-source/shown-names", test_shown_names);
    Test.add_func ("/stack-source/folder-date-added", test_folder_date_added);
    Test.add_func ("/stack-source/folder-name", test_folder_name);
    Test.add_func ("/stack-source/folder-live-update", test_folder_live_update);
    Test.add_func ("/stack-source/firefox-placeholder", test_firefox_placeholder_hidden);
    Test.add_func ("/stack-source/folder-missing", test_folder_missing);
    Test.add_func ("/stack-source/folder-finalized", test_folder_source_finalized);
    Test.add_func ("/stack-entry/download-stall", test_download_stall);
    Test.add_func ("/stack-source/applications", test_applications);
    Test.add_func ("/stack-source/applications-fan-flat", test_applications_fan_flat);
    Test.add_func ("/launcher-progress/feed", test_launcher_progress);
    Test.add_func ("/stack-source/downloads-tile", test_downloads_tile);
    Test.add_func ("/appcenter-jobs/parse", test_job_parsing);
    Test.add_func ("/appcenter-jobs/store", test_jobs_store);
    Test.add_func ("/appcenter-jobs/clear-keeps-fake", test_jobs_clear_keeps_fake);
    Test.add_func ("/stack-source/applications-jobs", test_applications_jobs);
    Test.add_func ("/fan-math/open", test_fan_pose_open);
    Test.add_func ("/fan-math/collapsed", test_fan_pose_collapsed);
    Test.add_func ("/app-folders/classify", test_classify);
    return Test.run ();
}
