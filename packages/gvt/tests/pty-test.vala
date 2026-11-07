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

    public Run (string[] argv) throws Error {
        Pid pid;
        pty = Gvt.Pty.spawn (null, argv, null, SpawnFlags.SEARCH_PATH, null, out pid);
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
        var timeout = Timeout.add_seconds (20, () => {
            loop.quit ();
            return Source.REMOVE;
        });
        loop.run ();
        Source.remove (timeout);
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

static int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/pty/output-then-exit", test_output_then_exit);
    Test.add_func ("/pty/resize", test_resize);
    Test.add_func ("/pty/write", test_write);
    Test.add_func ("/pty/read-cap", test_read_cap);
    Test.add_func ("/pty/exec-fail", test_exec_fail);
    Test.add_func ("/pty/close", test_close);
    Test.add_func ("/pty/runtime-argv", test_runtime_argv);
    return Test.run ();
}
