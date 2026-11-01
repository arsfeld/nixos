/*
 * tailscaled's LocalAPI over its unix socket: the IPN bus stream that keeps
 * `state` current, /status, and PATCH /prefs. All of it is async, so the
 * panel's main loop never waits on tailscaled.
 *
 * Writes succeed only for root and tailscaled's --operator user, which
 * modules/desktop/pantheon-tailscale.nix makes the desktop user; anyone else
 * gets 403.
 */
public class TailscaleIndicator.LocalApi : Object {
    private const string SOCKET = "/run/tailscale/tailscaled.sock";
    // tailscaled checks the Host header; the name is a convention, never resolved.
    private const string BASE = "http://local-tailscaled.sock/localapi/v0/";
    // NotifyInitialState | NotifyInitialPrefs | NotifyNoPrivateKeys.
    private const int WATCH_MASK = 2 | 4 | 16;
    private const uint MAX_BACKOFF_S = 30;

    public State state { get; construct; }

    private Soup.Session session;

    public LocalApi (State state) {
        Object (state: state);
    }

    construct {
        // timeout 0: the IPN bus can stay silent for hours, and libsoup's
        // default 60 s I/O timeout would cut it every minute. Four connections
        // per host so /status and a write never queue behind the stream.
        session = new Soup.Session.with_options (
            "remote-connectable", new UnixSocketAddress (SOCKET),
            "timeout", 0,
            "idle-timeout", 0,
            "max-conns-per-host", 4
        );
        watch.begin ();
    }

    /*
     * Follows the IPN bus for the life of the panel. When the stream ends or
     * fails (tailscaled stopped or restarting), state goes unreachable and the
     * stream reopens after 1 s, doubling to 30 s, reset by the first line read.
     */
    private async void watch () {
        uint backoff_s = 1;
        while (true) {
            try {
                var msg = new Soup.Message ("GET", BASE + "watch-ipn-bus?mask=%d".printf (WATCH_MASK));
                var stream = yield session.send_async (msg, Priority.DEFAULT, null);
                if (msg.status_code != Soup.Status.OK) {
                    throw new IOError.FAILED ("HTTP %u", msg.status_code);
                }
                var lines = new DataInputStream (stream);
                string? line;
                while ((line = yield lines.read_line_async (Priority.DEFAULT, null)) != null) {
                    backoff_s = 1;
                    apply_line (line);
                }
            } catch (Error e) {
                debug ("IPN bus: %s", e.message);
            }
            state.backend = Backend.UNREACHABLE;
            yield sleep (backoff_s);
            backoff_s = uint.min (backoff_s * 2, MAX_BACKOFF_S);
        }
    }

    private void apply_line (string line) {
        var parser = new Json.Parser ();
        try {
            parser.load_from_data (line);
        } catch (Error e) {
            debug ("IPN bus: unparseable line: %s", e.message);
            return;
        }
        var root = parser.get_root ();
        if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
            Model.apply_notify (state, root.get_object ());
        }
    }

    private async void sleep (uint seconds) {
        Timeout.add_seconds (seconds, sleep.callback);
        yield;
    }

    /* Null when tailscaled is unreachable or its reply is not a JSON object. */
    public async Status? status () {
        var msg = new Soup.Message ("GET", BASE + "status");
        try {
            var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, null);
            if (msg.status_code != Soup.Status.OK) {
                debug ("/status: HTTP %u", msg.status_code);
                return null;
            }
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                return null;
            }
            return Model.parse_status (root.get_object ());
        } catch (Error e) {
            debug ("/status: %s", e.message);
            return null;
        }
    }

    /* Each returns the HTTP status, or 0 when tailscaled could not be reached. */
    public async uint set_running (bool on) {
        return yield patch_prefs (Model.running_body (on));
    }

    public async uint set_exit_node (string id) {
        return yield patch_prefs (Model.exit_node_body (id));
    }

    private async uint patch_prefs (string body) {
        var msg = new Soup.Message ("PATCH", BASE + "prefs");
        msg.set_request_body_from_bytes ("application/json", new Bytes (body.data));
        try {
            yield session.send_and_read_async (msg, Priority.DEFAULT, null);
        } catch (Error e) {
            debug ("PATCH /prefs: %s", e.message);
            return 0;
        }
        return msg.status_code;
    }
}
