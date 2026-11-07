/*
 * The public enums, delegate and free function of VTE that elementary uses,
 * with VTE 0.84's names and values.
 */
namespace Gvt {
    public enum CursorShape {
        BLOCK,
        IBEAM,
        UNDERLINE
    }

    public enum Format {
        TEXT = 1,
        HTML = 2
    }

    /* Accepted for VTE compatibility; gvt's Pty has no use for them. */
    [Flags]
    public enum PtyFlags {
        NO_LASTLOG,
        NO_UTMP,
        NO_WTMP,
        NO_HELPER,
        NO_FALLBACK,
        NO_SESSION,
        NO_CTTY,
        DEFAULT = 0
    }

    /* The result of Terminal.spawn_async (): the child's pid, or -1 and the
     * error. */
    public delegate void TerminalSpawnAsyncCallback (Terminal terminal, Pid pid, Error? error);

    /* The user's login shell from the password database, else /bin/sh. */
    public string get_user_shell () {
        unowned Posix.Passwd? pw = Posix.getpwuid (Posix.getuid ());
        if (pw != null && pw.pw_shell != null && pw.pw_shell != "") {
            return pw.pw_shell;
        }
        return "/bin/sh";
    }
}
