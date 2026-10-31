/*
 * Turns a game gamemoded registered into the name the popover shows.
 *
 * Steam registers every game through its `reaper` process (gamemode-steam-watch
 * in modules/constellation/gaming.nix), so gamemoded's Executable reads
 * `reaper` for all of them. A reaper is named from Steam's app manifest
 * instead, using the AppId on its command line; anything else by its
 * executable's basename. Every lookup that fails falls back to a plainer
 * name, never to nothing.
 *
 * These take strings and paths, never /proc or $HOME, so tests can feed them.
 */
namespace GameModeIndicator.Names {
    /* /proc/<pid>/cmdline is NUL-separated, usually with a trailing NUL. */
    public string[] split_cmdline (uint8[] data) {
        string[] args = {};
        var current = new StringBuilder ();
        foreach (uint8 b in data) {
            if (b == 0) {
                args += current.str;
                current.truncate (0);
            } else {
                current.append_c ((char) b);
            }
        }
        if (current.len > 0) {
            args += current.str;
        }
        return args;
    }

    /* Steam starts games as `reaper SteamLaunch AppId=<id> -- <game…>`. */
    public string? app_id_from_args (string[] args) {
        foreach (unowned string arg in args) {
            if (arg == "--") {
                break;
            }
            if (arg.has_prefix ("AppId=")) {
                var id = arg.substring ("AppId=".length);
                return is_digits (id) ? id : null;
            }
        }
        return null;
    }

    /* The id goes into a file name, so anything but digits is rejected. */
    private bool is_digits (string text) {
        if (text == "") {
            return false;
        }
        for (int i = 0; i < text.length; i++) {
            if (!text[i].isdigit ()) {
                return false;
            }
        }
        return true;
    }

    /*
     * Every value of a `"key" "value"` pair in Valve's KeyValues text, with
     * VDF's C-style escapes undone. A regex per key is enough for the two
     * keys read here; there is no VDF parser.
     */
    public string[] vdf_values (string text, string key) {
        string[] values = {};
        try {
            var regex = new Regex ("\"%s\"\\s+\"((?:[^\"\\\\]|\\\\.)*)\"".printf (Regex.escape_string (key)));
            MatchInfo info;
            if (regex.match (text, 0, out info)) {
                do {
                    values += info.fetch (1).compress ();
                } while (info.next ());
            }
        } catch (RegexError e) {
            warning ("Could not read VDF key %s: %s", key, e.message);
        }
        return values;
    }

    /*
     * The main steamapps directory plus every library Steam lists in its
     * libraryfolders.vdf. The main library usually appears there too; looking
     * twice is harmless.
     */
    public string[] steamapps_dirs (string steamapps) {
        string[] dirs = { steamapps };
        string text;
        try {
            FileUtils.get_contents (Path.build_filename (steamapps, "libraryfolders.vdf"), out text);
        } catch (FileError e) {
            return dirs;
        }
        foreach (var path in vdf_values (text, "path")) {
            dirs += Path.build_filename (path, "steamapps");
        }
        return dirs;
    }

    public string? steam_name (string app_id, string[] dirs) {
        foreach (unowned string dir in dirs) {
            string text;
            try {
                FileUtils.get_contents (Path.build_filename (dir, "appmanifest_%s.acf".printf (app_id)), out text);
            } catch (FileError e) {
                continue;
            }
            var names = vdf_values (text, "name");
            if (names.length > 0 && names[0] != "") {
                return names[0];
            }
        }
        return null;
    }

    /* `args` is the game process's command line, or null if unreadable. */
    public string display_name (string executable, string[]? args, string[] dirs) {
        var basename = Path.get_basename (executable);
        if (basename != "reaper" || args == null) {
            return basename;
        }
        var id = app_id_from_args (args);
        if (id == null) {
            return basename;
        }
        return steam_name (id, dirs) ?? "Steam game %s".printf (id);
    }
}
