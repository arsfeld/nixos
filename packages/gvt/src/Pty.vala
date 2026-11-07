/*
 * Pty: a child process on a pseudo-terminal.
 *
 * spawn () forks the child onto the slave side and keeps the master, which
 * is `fd`. Output arrives through `data`, at most 64 KiB per main-loop
 * dispatch, and `exited` fires once the child's status is known and every
 * byte it wrote has been delivered. write () never blocks.
 *
 * This file does not touch libghostty.
 */
namespace Gvt {
    public class Pty : Object {
        private const size_t READ_CAP = 65536;

        public int fd { get; construct; }

        internal signal void data (uint8[] chunk);
        /* The raw wait status, as waitpid reports it and VTE's child-exited
         * passes it on: use Process.exit_status () to get the exit code. */
        internal signal void exited (int status);

        private uint read_source = 0;
        private uint write_source = 0;
        private uint child_source = 0;
        private bool eof = false;
        private bool have_status = false;
        private int wait_status = 0;
        private bool exit_reported = false;
        private bool closed = false;
        private Pid child_pid = 0;
        private ByteArray out_queue = new ByteArray ();
        private uint8[] read_buf = new uint8[READ_CAP];

        private Pty (int fd) {
            Object (fd: fd);
        }

        ~Pty () {
            close ();
        }

        /* Stops watching, hangs up the child's process group (it leads its own
         * session) and closes the master. Safe to call twice; `exited` does not
         * fire afterwards. */
        internal void close () {
            if (closed) {
                return;
            }
            closed = true;
            if (read_source != 0) {
                Source.remove (read_source);
                read_source = 0;
            }
            if (write_source != 0) {
                Source.remove (write_source);
                write_source = 0;
            }
            if (child_source != 0) {
                Source.remove (child_source);
                child_source = 0;
                Posix.kill (-(Posix.pid_t) child_pid, Posix.Signal.HUP);
                /* Still reap it when it goes, without telling anyone. */
                ChildWatch.add (child_pid, (p, st) => Process.close_pid (p));
            }
            Posix.close (fd);
        }

        internal static Pty spawn (string? cwd, string[] argv, string[]? envv,
                                   SpawnFlags flags,
                                   owned SpawnChildSetupFunc? setup,
                                   out Pid pid) throws Error {
            pid = 0;
            if (argv.length == 0) {
                throw new SpawnError.FAILED ("empty argv");
            }

            int master, slave;
            if (GvtPosix.openpty (out master, out slave, null, null, null) != 0) {
                throw new SpawnError.FAILED ("openpty: %s", Posix.strerror (Posix.errno));
            }
            Posix.fcntl (master, Posix.F_SETFD, Posix.FD_CLOEXEC);
            Posix.fcntl (slave, Posix.F_SETFD, Posix.FD_CLOEXEC);

            /* The child reports a failed exec by writing errno here. The
             * write end closes on a successful exec, so a read of zero bytes
             * means the program started. */
            int[] report = new int[2];
            if (GvtPosix.pipe2 (report, Posix.O_CLOEXEC) != 0) {
                var err = Posix.errno;
                Posix.close (master);
                Posix.close (slave);
                throw new SpawnError.FAILED ("pipe: %s", Posix.strerror (err));
            }

            /* Everything the child needs is built before fork (), which keeps
             * the child to async-signal-safe calls. */
            var env = build_env (envv);
            var args = null_terminated (argv);
            var envp = null_terminated (env);
            var file = argv[0];
            var search = (flags & SpawnFlags.SEARCH_PATH) != 0;

            var child = Posix.fork ();
            if (child < 0) {
                var err = Posix.errno;
                Posix.close (master);
                Posix.close (slave);
                Posix.close (report[0]);
                Posix.close (report[1]);
                throw new SpawnError.FAILED ("fork: %s", Posix.strerror (err));
            }

            if (child == 0) {
                Posix.setsid ();
                GvtPosix.ioctl_int (slave, GvtPosix.TIOCSCTTY, 0);
                Posix.dup2 (slave, 0);
                Posix.dup2 (slave, 1);
                Posix.dup2 (slave, 2);
                /* The slave and master are close-on-exec, so only the dup2
                 * copies reach the program. */
                if (cwd != null && Posix.chdir (cwd) != 0) {
                    child_fail (report[1]);
                }
                if (setup != null) {
                    setup ();
                }
                if (search) {
                    GvtPosix.execvpe (file, args, envp);
                } else {
                    GvtPosix.execve (file, args, envp);
                }
                child_fail (report[1]);
            }

            /* The parent must not hold the slave open, or the master never
             * sees EOF once the child is gone. */
            Posix.close (slave);
            Posix.close (report[1]);

            int child_errno = 0;
            ssize_t n = 0;
            do {
                n = Posix.read (report[0], &child_errno, sizeof (int));
            } while (n < 0 && Posix.errno == Posix.EINTR);
            Posix.close (report[0]);

            if (n > 0) {
                int status;
                Posix.waitpid (child, out status, 0);
                Posix.close (master);
                throw new SpawnError.FAILED ("Failed to execute %s: %s",
                                             argv[0], Posix.strerror (child_errno));
            }

            pid = (Pid) child;
            var pty = new Pty (master);
            pty.start (pid);
            return pty;
        }

        /* Reports errno to the parent and leaves without running any
         * atexit handler or flushing the parent's buffers. */
        private static void child_fail (int report_fd) {
            int e = Posix.errno;
            if (Posix.write (report_fd, &e, sizeof (int)) < 0) {
                /* Nothing more to do: the parent sees a short read. */
            }
            Posix._exit (127);
        }

        /* Copies with a NULL after the last element, whatever the source. */
        private static string[] null_terminated (string[] src) {
            var copy = new string[src.length + 1];
            for (var i = 0; i < src.length; i++) {
                copy[i] = src[i];
            }
            return copy;
        }

        private static string[] build_env (string[]? envv) {
            var env = envv != null ? envv : Environ.get ();
            env = Environ.set_variable (env, "TERM", "xterm-256color", false);
            env = Environ.set_variable (env, "COLORTERM", "truecolor", false);
            return env;
        }

        private void start (Pid pid) {
            child_pid = pid;
            var flags = Posix.fcntl (fd, Posix.F_GETFL);
            Posix.fcntl (fd, Posix.F_SETFL, flags | Posix.O_NONBLOCK);

            /* Below the frame clock (GDK_PRIORITY_REDRAW) and input events, as
             * VTE reads its child: a child that never stops writing still
             * lets the window redraw and take keys between reads. */
            read_source = watch (IOCondition.IN | IOCondition.HUP | IOCondition.ERR, on_readable,
                                 Priority.DEFAULT_IDLE);
            child_source = ChildWatch.add (pid, on_child);
        }

        /* No-op once closed: the fd number may belong to someone else by then. */
        internal void write (uint8[] bytes) {
            if (closed || bytes.length == 0) {
                return;
            }
            out_queue.append (bytes);
            drain ();
        }

        private void drain () {
            while (out_queue.len > 0) {
                var n = Posix.write (fd, out_queue.data, out_queue.len);
                if (n > 0) {
                    out_queue.remove_range (0, (uint) n);
                    continue;
                }
                var err = Posix.errno;
                if (n < 0 && err == Posix.EINTR) {
                    continue;
                }
                if (n < 0 && err == Posix.EAGAIN) {
                    if (write_source == 0) {
                        write_source = watch (IOCondition.OUT, on_writable);
                    }
                    return;
                }
                /* The child is gone: the bytes have nowhere to go. */
                out_queue.set_size (0);
                return;
            }
        }

        /* The channel is only a way to watch the fd: all I/O goes through
         * read () and write (), and the fd stays open when it goes away. */
        private uint watch (IOCondition condition, owned IOFunc func, int priority = Priority.DEFAULT) {
            var channel = new IOChannel.unix_new (fd);
            channel.set_close_on_unref (false);
            return channel.add_watch_full (priority, condition, (owned) func);
        }

        private bool on_writable (IOChannel source, IOCondition condition) {
            write_source = 0;
            drain ();
            return Source.REMOVE;
        }

        private bool on_readable (IOChannel source, IOCondition condition) {
            ref ();
            var keep = Source.CONTINUE;

            var n = Posix.read (fd, read_buf, READ_CAP);
            if (n > 0) {
                data (read_buf[0:n]);
            } else if (n == 0 || (Posix.errno != Posix.EAGAIN && Posix.errno != Posix.EINTR)) {
                /* EIO is how Linux reports that every slave holder is gone. */
                eof = true;
                read_source = 0;
                keep = Source.REMOVE;
                maybe_exited ();
            }

            unref ();
            return keep;
        }

        private void on_child (Pid pid, int status) {
            Process.close_pid (pid);
            child_source = 0;
            have_status = true;
            wait_status = status;
            maybe_exited ();
        }

        private void maybe_exited () {
            if (eof && have_status && !exit_reported) {
                exit_reported = true;
                exited (wait_status);
            }
        }

        /* No-op once closed, like write (). */
        internal void set_size (uint16 cols, uint16 rows, uint16 px_w, uint16 px_h) {
            if (closed) {
                return;
            }
            var ws = GvtPosix.WinSize () {
                ws_row = rows, ws_col = cols, ws_xpixel = px_w, ws_ypixel = px_h
            };
            GvtPosix.ioctl_winsize (fd, GvtPosix.TIOCSWINSZ, ref ws);
        }
    }
}
