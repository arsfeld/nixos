// Pty against real children. Compiled together with src/Pty.vala, because Pty
// is internal to the library.

class Run : Object {
    public ByteArray output = new ByteArray ();
    public int max_chunk = 0;
    public int chunks = 0;
    public bool exited_seen = false;
    public int status = -1;
    public size_t bytes_at_exit = 0;
    public Gvt.Pty pty;
    public MainLoop loop = new MainLoop ();

    public Pid pid;

    public Run (string[] argv, string[]? envv = null) throws Error {
        pty = Gvt.Pty.spawn (null, argv, envv, SpawnFlags.SEARCH_PATH, null, out pid);
        pty.data.connect ((chunk) => {
            output.append (chunk);
            chunks++;
            if (chunk.length > max_chunk) {
                max_chunk = chunk.length;
            }
        });
        pty.exited.connect ((s) => {
            exited_seen = true;
            status = s;
            bytes_at_exit = output.len;
            loop.quit ();
        });
    }

    public string text {
        owned get {
            var b = new StringBuilder ();
            b.append_len ((string) output.data, output.len);
            return b.str;
        }
    }

    public void wait_for_exit () {
        var timed_out = false;
        var timeout = Timeout.add_seconds (20, () => {
            timed_out = true;
            loop.quit ();
            return Source.REMOVE;
        });
        loop.run ();
        if (!timed_out) {
            Source.remove (timeout);
        }
        assert_true (exited_seen);
    }

    /* Runs the loop until `text` contains `needle`. */
    public void wait_for (string needle) {
        var timeout = Timeout.add_seconds (20, () => {
            loop.quit ();
            return Source.REMOVE;
        });
        var handler = pty.data.connect (() => {
            if (text.contains (needle)) {
                loop.quit ();
            }
        });
        if (!text.contains (needle)) {
            loop.run ();
        }
        pty.disconnect (handler);
        Source.remove (timeout);
        assert_true (text.contains (needle));
    }
}

static void test_output_then_exit () {
    try {
        var run = new Run ({ "sh", "-c", "printf X; exit 3" });
        run.wait_for_exit ();
        assert_cmpstr (run.text, CompareOperator.EQ, "X");
        assert_cmpint ((int) run.bytes_at_exit, CompareOperator.EQ, 1);
        assert_true (Process.if_exited (run.status));
        assert_cmpint (Process.exit_status (run.status), CompareOperator.EQ, 3);
    } catch (Error e) {
        error ("%s", e.message);
    }
}

static void test_resize () {
    try {
        Pid pid;
        var pty = Gvt.Pty.spawn (null, { "sh", "-c", "sleep 0.2; stty size" }, null,
                                 SpawnFlags.SEARCH_PATH, null, out pid);
        pty.set_size (42, 7, 0, 0);
        var out_text = new StringBuilder ();
        var loop = new MainLoop ();
        pty.data.connect ((chunk) => out_text.append_len ((string) chunk, chunk.length));
        pty.exited.connect (() => loop.quit ());
        loop.run ();
        assert_true (out_text.str.contains ("7 42"));
    } catch (Error e) {
        error ("%s", e.message);
    }
}

static void test_write () {
    try {
        var run = new Run ({ "cat" });
        run.pty.write ("abc\n".data);
        run.wait_for ("abc");
        /* ^D at the start of a line makes cat exit. */
        run.pty.write ({ 4 });
        run.wait_for_exit ();
    } catch (Error e) {
        error ("%s", e.message);
    }
}

static void test_read_cap () {
    try {
        var run = new Run ({ "sh", "-c", "head -c 1000000 /dev/zero" });
        run.wait_for_exit ();
        assert_cmpint (run.max_chunk, CompareOperator.LE, 65536);
        assert_cmpint ((int) run.output.len, CompareOperator.EQ, 1000000);
        assert_cmpint (run.chunks, CompareOperator.GE, 16);
    } catch (Error e) {
        error ("%s", e.message);
    }
}

static void test_exec_fail () {
    bool threw = false;
    try {
        Pid pid;
        Gvt.Pty.spawn (null, { "/nonexistent" }, null, 0, null, out pid);
    } catch (Error e) {
        threw = e is SpawnError;
    }
    assert_true (threw);
}

/* Once closed, write and set_size leave the old fd number alone, even after
 * another PTY's master has taken it. */
static void test_closed_is_inert () {
    try {
        Pid pid;
        var pty = Gvt.Pty.spawn (null, { "sleep", "100" }, null, SpawnFlags.SEARCH_PATH, null, out pid);
        var old_fd = pty.fd;
        pty.close ();

        int master, slave;
        assert_cmpint (GvtPosix.openpty (out master, out slave, null, null, null), CompareOperator.EQ, 0);
        var size = GvtPosix.WinSize () { ws_row = 3, ws_col = 7 };
        GvtPosix.ioctl_winsize (master, GvtPosix.TIOCSWINSZ, ref size);
        if (master != old_fd) {
            assert_cmpint (Posix.dup2 (master, old_fd), CompareOperator.EQ, old_fd);
            Posix.close (master);
        }
        Posix.fcntl (slave, Posix.F_SETFL, Posix.fcntl (slave, Posix.F_GETFL) | Posix.O_NONBLOCK);

        pty.write ("leak\n".data);
        pty.set_size (10, 4, 100, 80);

        var buf = new uint8[64];
        assert_cmpint ((int) Posix.read (slave, buf, buf.length), CompareOperator.EQ, -1);
        assert_cmpint (Posix.errno, CompareOperator.EQ, Posix.EAGAIN);
        var now = GvtPosix.WinSize ();
        GvtPosix.ioctl_winsize (slave, GvtPosix.TIOCGWINSZ, ref now);
        assert_cmpuint (now.ws_col, CompareOperator.EQ, 7);
        assert_cmpuint (now.ws_row, CompareOperator.EQ, 3);
        Posix.close (old_fd);
        Posix.close (slave);
    } catch (Error e) {
        error ("%s", e.message);
    }
}

static void test_close () {
    try {
        Pid pid;
        var pty = Gvt.Pty.spawn (null, { "sleep", "100" }, null, SpawnFlags.SEARCH_PATH, null, out pid);
        var fired = false;
        pty.exited.connect (() => fired = true);
        pty.close ();
        pty.close ();
        /* The reaper runs from the main loop. */
        var loop = new MainLoop ();
        Timeout.add (50, () => {
            if (Posix.kill ((Posix.pid_t) pid, 0) != 0 || fired) {
                loop.quit ();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
        var limit = Timeout.add_seconds (10, () => {
            loop.quit ();
            return Source.REMOVE;
        });
        loop.run ();
        Source.remove (limit);
        assert_true (Posix.kill ((Posix.pid_t) pid, 0) != 0);
        /* Let any stray emission surface. */
        var ctx = MainContext.default ();
        for (var i = 0; i < 20; i++) {
            ctx.iteration (false);
        }
        assert_false (fired);
    } catch (Error e) {
        error ("%s", e.message);
    }
}

static void test_runtime_argv () {
    try {
        var args = new GenericArray<string> ();
        args.add ("sh");
        args.add ("-c");
        args.add ("printf " + "%s" + " 'dyn" + "amic'");
        var run = new Run (args.data);
        run.wait_for_exit ();
        assert_cmpstr (run.text, CompareOperator.EQ, "dynamic");
    } catch (Error e) {
        error ("%s", e.message);
    }
}

/* envv is merged over the parent's environment, as VTE does: elementary
 * passes its own variables and the shell still needs WAYLAND_DISPLAY,
 * DBUS_SESSION_BUS_ADDRESS and the rest. */
static void test_env_merged () {
    try {
        Environment.set_variable ("GVT_INHERITED", "parent", true);
        var run = new Run ({ "sh", "-c", "printf '%s/%s/%s' \"$GVT_INHERITED\" \"$GVT_EXTRA\" \"$TERM\"" },
                           { "GVT_EXTRA=extra" });
        run.wait_for_exit ();
        assert_cmpstr (run.text, CompareOperator.EQ, "parent/extra/xterm-256color");
    } catch (Error e) {
        error ("%s", e.message);
    }
}

/* A background job that keeps the slave open does not keep `exited` from
 * firing: like VTE, Pty waits a short while for EOF after the child goes,
 * then reports anyway. The job ignores SIGHUP, as a nohup'd one or one in
 * an interactive shell's own process group survives the shell. */
static void test_exit_with_background_holder () {
    try {
        var run = new Run ({ "sh", "-c", "trap '' HUP; sleep 30 & printf go; exit 4" });
        var timer = new Timer ();
        run.wait_for_exit ();
        var elapsed = timer.elapsed ();
        Posix.kill (-(Posix.pid_t) run.pid, Posix.Signal.KILL);
        assert_cmpfloat (elapsed, CompareOperator.LT, 3.5);
        assert_true (Process.if_exited (run.status));
        assert_cmpint (Process.exit_status (run.status), CompareOperator.EQ, 4);
        assert_cmpstr (run.text, CompareOperator.EQ, "go");
    } catch (Error e) {
        error ("%s", e.message);
    }
}

/* The child starts with no blocked or ignored signals and none of the
 * parent's stray descriptors, whatever the parent had. */
static void test_child_clean_slate () {
    try {
        Posix.sigset_t block, old, ignored;
        Posix.sigemptyset (out block);
        Posix.sigaddset (ref block, Posix.Signal.USR1);
        Posix.sigprocmask (Posix.SIG_BLOCK, block, out old);
        var old_usr2 = GvtPosix.signal (Posix.Signal.USR2, GvtPosix.SIG_IGN);
        var stray = Posix.open ("/dev/null", Posix.O_RDONLY);
        assert_cmpint (stray, CompareOperator.GT, 2);

        var run = new Run ({ "sh", "-c",
                             "grep -E '^Sig(Blk|Ign)' /proc/self/status; " +
                             "test -e /proc/$$/fd/%d && echo LEAK || echo CLEAN".printf (stray) });
        run.wait_for_exit ();

        Posix.close (stray);
        GvtPosix.signal (Posix.Signal.USR2, old_usr2);
        Posix.sigprocmask (Posix.SIG_SETMASK, old, out ignored);

        assert_true (run.text.contains ("SigBlk:\t0000000000000000"));
        /* The shell ignores nothing it was not told to; USR2 is 1 << 11. */
        assert_false (run.text.contains ("SigIgn:\t0000000000000800"));
        assert_true (run.text.contains ("CLEAN"));
    } catch (Error e) {
        error ("%s", e.message);
    }
}

static int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/pty/output-then-exit", test_output_then_exit);
    Test.add_func ("/pty/resize", test_resize);
    Test.add_func ("/pty/write", test_write);
    Test.add_func ("/pty/read-cap", test_read_cap);
    Test.add_func ("/pty/exec-fail", test_exec_fail);
    Test.add_func ("/pty/close", test_close);
    Test.add_func ("/pty/closed-is-inert", test_closed_is_inert);
    Test.add_func ("/pty/runtime-argv", test_runtime_argv);
    Test.add_func ("/pty/env-merged", test_env_merged);
    Test.add_func ("/pty/exit-with-background-holder", test_exit_with_background_holder);
    Test.add_func ("/pty/child-clean-slate", test_child_clean_slate);
    return Test.run ();
}
