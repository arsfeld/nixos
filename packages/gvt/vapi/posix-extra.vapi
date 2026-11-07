/* The few POSIX/Linux calls Pty needs that posix.vapi lacks. */
[CCode (cheader_filename = "pty.h,sys/ioctl.h,termios.h,unistd.h,fcntl.h")]
namespace GvtPosix {
    [CCode (cname = "struct winsize", has_type_id = false)]
    public struct WinSize {
        public uint16 ws_row;
        public uint16 ws_col;
        public uint16 ws_xpixel;
        public uint16 ws_ypixel;
    }

    [CCode (cname = "TIOCSCTTY")]
    public const ulong TIOCSCTTY;
    [CCode (cname = "TIOCSWINSZ")]
    public const ulong TIOCSWINSZ;
    [CCode (cname = "TIOCGWINSZ")]
    public const ulong TIOCGWINSZ;

    [CCode (cname = "openpty")]
    public int openpty (out int amaster, out int aslave, void* name, void* termp, void* winp);

    [CCode (cname = "ioctl")]
    public int ioctl_int (int fd, ulong request, int arg);
    [CCode (cname = "ioctl")]
    public int ioctl_winsize (int fd, ulong request, ref WinSize ws);

    [CCode (cname = "execvpe", array_length = false)]
    public int execvpe (string file, [CCode (array_length = false)] string[] argv, [CCode (array_length = false)] string[] envp);
    [CCode (cname = "execve", array_length = false)]
    public int execve (string file, [CCode (array_length = false)] string[] argv, [CCode (array_length = false)] string[] envp);

    [CCode (cname = "pipe2")]
    public int pipe2 ([CCode (array_length = false)] int[] fds, int flags);

    /* Signal dispositions as plain pointers, so a child can reset every
     * signal without Vala's delegate machinery. */
    [CCode (cname = "NSIG", cheader_filename = "signal.h")]
    public const int NSIG;
    [CCode (cname = "SIG_DFL", cheader_filename = "signal.h")]
    public void* SIG_DFL;
    [CCode (cname = "SIG_IGN", cheader_filename = "signal.h")]
    public void* SIG_IGN;
    [CCode (cname = "signal", cheader_filename = "signal.h")]
    public void* signal (int signum, void* handler);

    [CCode (cname = "CLOSE_RANGE_CLOEXEC", cheader_filename = "linux/close_range.h")]
    public const uint CLOSE_RANGE_CLOEXEC;
    [CCode (cname = "close_range", cheader_filename = "unistd.h")]
    public int close_range (uint first, uint last, int flags);
}
