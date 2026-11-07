// Helpers shared by the widget tests (terminal-test, renderer-test).

namespace TestUtil {
    public delegate bool Condition ();

    /* Iterates the default main context until cond () holds or `seconds`
     * pass; returns cond (). */
    public bool wait_until (Condition cond, double seconds = 10) {
        var timer = new Timer ();
        var ctx = MainContext.default ();
        while (!cond ()) {
            if (timer.elapsed () > seconds) {
                return cond ();
            }
            if (!ctx.iteration (false)) {
                Thread.usleep (1000);
            }
        }
        return true;
    }

    /* Iterates the default main context for `ms` milliseconds. */
    public void run_for (uint ms) {
        var timer = new Timer ();
        var ctx = MainContext.default ();
        while (timer.elapsed () * 1000 < ms) {
            if (!ctx.iteration (false)) {
                Thread.usleep (1000);
            }
        }
    }

    /* A terminal with the fonts.conf monospace, so cell metrics are stable. */
    public Gvt.Terminal new_terminal () {
        var t = new Gvt.Terminal ();
        t.set_font (Pango.FontDescription.from_string ("DejaVu Sans Mono 10"));
        return t;
    }

    /* Measures both ways, as a parent does before allocating. */
    public void measure (Gtk.Widget w) {
        int min, nat, min_b, nat_b;
        w.measure (Gtk.Orientation.HORIZONTAL, -1, out min, out nat, out min_b, out nat_b);
        w.measure (Gtk.Orientation.VERTICAL, -1, out min, out nat, out min_b, out nat_b);
    }

    /* Shows `t` in a window and waits until it has been drawn. */
    public Gtk.Window present (Gvt.Terminal t) {
        var window = new Gtk.Window ();
        window.child = t;
        window.present ();
        assert_true (wait_until (() => t.get_mapped () && t.renderer.frames > 0));
        run_for (100);
        return window;
    }

    /* Spawns argv, asserts the spawn worked and returns the pid. */
    public Pid spawn (Gvt.Terminal t, string[] argv) {
        Pid result = 0;
        Error? failure = null;
        bool done = false;
        t.spawn_async (Gvt.PtyFlags.DEFAULT, null, argv, null, SpawnFlags.SEARCH_PATH,
                       null, -1, null, (term, pid, error) => {
            result = pid;
            failure = error;
            done = true;
        });
        assert_true (wait_until (() => done));
        assert_true (failure == null);
        assert_true (result > 0);
        return result;
    }
}
