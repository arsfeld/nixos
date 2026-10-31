/*
 * Unit tests for Names.vala, run by `meson test` in the package's checkPhase.
 * Steam trees are built under a fresh temporary directory per test.
 */
using GameModeIndicator;

uint8[] nul_joined (string[] parts) {
    uint8[] result = {};
    foreach (unowned string part in parts) {
        foreach (uint8 b in part.data) {
            result += b;
        }
        result += 0;
    }
    return result;
}

string tmp_tree () {
    try {
        return DirUtils.make_tmp ("gamemode-indicator-XXXXXX");
    } catch (FileError e) {
        error ("make_tmp: %s", e.message);
    }
}

void write (string path, string text) {
    DirUtils.create_with_parents (Path.get_dirname (path), 0755);
    // Not FileUtils.set_contents: with this valac/glib pair its binding
    // reaches g_file_set_contents_full with the wrong arguments and segfaults.
    var stream = FileStream.open (path, "w");
    if (stream == null) {
        error ("write %s: cannot open", path);
    }
    stream.puts (text);
}

string manifest (string id, string name) {
    return "\"AppState\"\n{\n\t\"appid\"\t\t\"%s\"\n\t\"name\"\t\t\"%s\"\n\t\"installdir\"\t\t\"x\"\n}\n".printf (id, name);
}

int main (string[] args) {
    Test.init (ref args);

    Test.add_func ("/names/split-cmdline", () => {
        var parts = Names.split_cmdline (nul_joined ({ "reaper", "SteamLaunch", "AppId=620", "--", "/game" }));
        assert_cmpint (parts.length, CompareOperator.EQ, 5);
        assert_cmpstr (parts[2], CompareOperator.EQ, "AppId=620");
        assert_cmpstr (parts[4], CompareOperator.EQ, "/game");
    });

    Test.add_func ("/names/split-cmdline-no-trailing-nul", () => {
        var data = nul_joined ({ "a", "b" });
        var parts = Names.split_cmdline (data[0:data.length - 1]);
        assert_cmpint (parts.length, CompareOperator.EQ, 2);
        assert_cmpstr (parts[1], CompareOperator.EQ, "b");
    });

    Test.add_func ("/names/app-id", () => {
        assert_cmpstr (Names.app_id_from_args ({ "reaper", "SteamLaunch", "AppId=620", "--", "x" }), CompareOperator.EQ, "620");
        // After `--` the arguments belong to the game.
        assert_cmpstr (Names.app_id_from_args ({ "reaper", "--", "AppId=620" }), CompareOperator.EQ, null);
        // Digits only: the id becomes part of a file name.
        assert_cmpstr (Names.app_id_from_args ({ "reaper", "AppId=../x" }), CompareOperator.EQ, null);
        assert_cmpstr (Names.app_id_from_args ({ "reaper", "AppId=" }), CompareOperator.EQ, null);
    });

    Test.add_func ("/names/vdf-escapes", () => {
        var values = Names.vdf_values ("\"name\"\t\t\"Foo \\\"Bar\\\"\"\n\"names\"\t\"no\"\n", "name");
        assert_cmpint (values.length, CompareOperator.EQ, 1);
        assert_cmpstr (values[0], CompareOperator.EQ, "Foo \"Bar\"");
    });

    Test.add_func ("/names/main-library", () => {
        var steamapps = Path.build_filename (tmp_tree (), "steamapps");
        write (Path.build_filename (steamapps, "appmanifest_620.acf"), manifest ("620", "Portal 2"));
        var dirs = Names.steamapps_dirs (steamapps);
        assert_cmpstr (Names.display_name ("/x/ubuntu12_32/reaper", { "reaper", "SteamLaunch", "AppId=620", "--", "g" }, dirs), CompareOperator.EQ, "Portal 2");
    });

    Test.add_func ("/names/second-library", () => {
        var root = tmp_tree ();
        var steamapps = Path.build_filename (root, "steamapps");
        var library = Path.build_filename (root, "games");
        write (Path.build_filename (steamapps, "libraryfolders.vdf"),
            "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"%s\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"%s\"\n\t}\n}\n".printf (root, library));
        write (Path.build_filename (library, "steamapps", "appmanifest_1091500.acf"), manifest ("1091500", "Cyberpunk 2077"));
        var dirs = Names.steamapps_dirs (steamapps);
        assert_cmpint (dirs.length, CompareOperator.EQ, 3);
        assert_cmpstr (Names.steam_name ("1091500", dirs), CompareOperator.EQ, "Cyberpunk 2077");
    });

    Test.add_func ("/names/fallbacks", () => {
        var dirs = Names.steamapps_dirs (Path.build_filename (tmp_tree (), "steamapps"));
        assert_cmpstr (Names.display_name ("/x/reaper", { "reaper", "AppId=999" }, dirs), CompareOperator.EQ, "Steam game 999");
        assert_cmpstr (Names.display_name ("/x/reaper", null, dirs), CompareOperator.EQ, "reaper");
        assert_cmpstr (Names.display_name ("/nix/store/abc-game/bin/witcher3", null, dirs), CompareOperator.EQ, "witcher3");
    });

    return Test.run ();
}
