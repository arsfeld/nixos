/*
 * Follows gamemoded on the session bus. `count` is its ClientCount, the number
 * of registered games, or 0 while gamemoded is not running. It never starts
 * gamemoded: gamemoded's absence just means no game is running.
 */
public struct GameModeIndicator.Game {
    public int pid;
    public string executable;
}

public class GameModeIndicator.Client : Object {
    private const string NAME = "com.feralinteractive.GameMode";
    private const string PATH = "/com/feralinteractive/GameMode";
    private const string IFACE = "com.feralinteractive.GameMode";
    private const string GAME_IFACE = "com.feralinteractive.GameMode.Game";
    private const int TIMEOUT_MS = 1000;

    public int count { get; private set; default = 0; }

    private DBusProxy? proxy = null;
    // Bumped on every appear/vanish, so a proxy that finishes connecting after
    // gamemoded has already gone again is dropped instead of kept.
    private uint generation = 0;

    construct {
        Bus.watch_name (BusType.SESSION, NAME, BusNameWatcherFlags.NONE, on_appeared, on_vanished);
    }

    private void on_appeared (DBusConnection connection, string name, string owner) {
        connect_proxy.begin (connection, ++generation);
    }

    private void on_vanished (DBusConnection? connection, string name) {
        generation++;
        proxy = null;
        count = 0;
    }

    private async void connect_proxy (DBusConnection connection, uint my_generation) {
        try {
            var p = yield new DBusProxy (connection, DBusProxyFlags.DO_NOT_AUTO_START, null, NAME, PATH, IFACE, null);
            if (my_generation != generation) {
                return;
            }
            // gamemoded emits PropertiesChanged for ClientCount (EMITS_CHANGE).
            // Use the signal's sender, not `p`: capturing `p` would make the proxy own a
            // closure that owns the proxy, so dropping `proxy` could never free it.
            p.g_properties_changed.connect ((sender, changed, invalidated) => read_count (sender));
            proxy = p;
            read_count (p);
        } catch (Error e) {
            warning ("Could not follow gamemoded: %s", e.message);
        }
    }

    private void read_count (DBusProxy p) {
        var value = p.get_cached_property ("ClientCount");
        count = (value != null && value.is_of_type (VariantType.INT32)) ? value.get_int32 () : 0;
    }

    /* Every registered game. Empty if gamemoded is gone or the call fails. */
    public async Game[] list_games () {
        Game[] games = {};
        var p = proxy;
        if (p == null) {
            return games;
        }
        var connection = p.get_connection ();
        try {
            var reply = yield connection.call (NAME, PATH, IFACE, "ListGames", null,
                new VariantType ("(a(io))"), DBusCallFlags.NONE, TIMEOUT_MS, null);
            var list = reply.get_child_value (0);
            for (size_t i = 0; i < list.n_children (); i++) {
                var entry = list.get_child_value (i);
                var exe = yield executable (connection, entry.get_child_value (1).get_string ());
                if (exe != null) {
                    Game game = { entry.get_child_value (0).get_int32 (), exe };
                    games += game;
                }
            }
        } catch (Error e) {
            warning ("Could not list GameMode games: %s", e.message);
        }
        return games;
    }

    /* Null when the game unregistered between ListGames and this call. */
    private async string? executable (DBusConnection connection, string path) {
        try {
            var reply = yield connection.call (NAME, path, "org.freedesktop.DBus.Properties", "Get",
                new Variant ("(ss)", GAME_IFACE, "Executable"),
                new VariantType ("(v)"), DBusCallFlags.NONE, TIMEOUT_MS, null);
            var value = reply.get_child_value (0).get_variant ();
            return value.is_of_type (VariantType.STRING) ? value.get_string () : null;
        } catch (Error e) {
            return null;
        }
    }
}
