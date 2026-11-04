/*
 * Turns a game gamemoded registered into the name the popover shows.
 *
 * gamemoded records a game's Executable once, when it registers, so it goes
 * stale when the process execs afterwards. Steam's launch chain does exactly
 * that: libgamemodeauto, preloaded into it, registers `env` (coreutils) and a
 * bash wrapper that then exec into `reaper` and `srt-bwrap`. So a game is
 * named from its *current* executable and command line, read from /proc, and
 * gamemoded's Executable is only the fallback for a process already gone.
 *
 * Every Steam game runs under a `reaper SteamLaunch AppId=<id>` process
 * (gamemode-steam-watch in modules/gaming.nix registers it too). Any
 * registered process that is a reaper, or descends from one, is named from
 * Steam's app manifest using that AppId; anything else by its executable's
 * basename. Every lookup that fails falls back to a plainer name, never to
 * nothing.
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

    /* A process as /proc shows it now; either field is null if unreadable. */
    public struct Proc {
        public string? exe;
        public string[]? args;
    }

    /* The parent pid from /proc/<pid>/stat, or 0. comm may hold ")" and spaces. */
    public int ppid_from_stat (string stat) {
        var close = stat.last_index_of_char (')');
        if (close < 0) {
            return 0;
        }
        var fields = stat.substring (close + 1).strip ().split (" ");
        return fields.length >= 2 ? int.parse (fields[1]) : 0;
    }

    private string? steam_app_id (Proc proc) {
        if (proc.exe == null || proc.args == null || Path.get_basename (proc.exe) != "reaper") {
            return null;
        }
        return app_id_from_args (proc.args);
    }

    /*
     * `chain` is the registered process followed by its ancestors, nearest
     * first; `executable` is what gamemoded recorded at registration.
     */
    public string display_name (string executable, Proc[] chain, string[] dirs) {
        foreach (unowned Proc proc in chain) {
            var id = steam_app_id (proc);
            if (id != null) {
                return steam_name (id, dirs) ?? "Steam game %s".printf (id);
            }
        }
        var current = chain.length > 0 ? chain[0].exe : null;
        return Path.get_basename (current ?? executable);
    }

    /* One row per game: a Steam game can register several of its processes. */
    public string[] unique (string[] names) {
        string[] result = {};
        foreach (unowned string name in names) {
            if (!(name in result)) {
                result += name;
            }
        }
        return result;
    }
}
