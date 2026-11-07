/*
 * Engine: the terminal state, on libghostty-vt.
 *
 * This is the only code in gvt that calls the libghostty C API
 * (vapi/libghostty-vt.vapi). Everything else talks to an Engine: it feeds
 * the child's output in with write (), reads state back through the
 * properties and text_range (), and hears about terminal effects through the
 * signals, which libghostty raises synchronously from inside write ().
 *
 * Rows are absolute ("screen" rows): row 0 is the oldest scrollback row, and
 * the active screen starts at scrollback_rows.
 */
namespace Gvt {
    /* Answers a clipboard read. Call it with the clipboard text, or null to
     * refuse, before the clipboard_read_requested handler returns: libghostty
     * takes the answer synchronously, and a later call is ignored. */
    internal delegate void ClipboardReply (string? text);

    internal class Engine : Object {
        private GhosttyVt.Terminal? terminal = null;
        private GhosttyVt.RenderState? state = null;

        /* Guards against re-entering vt_write from a signal handler, which
         * libghostty does not support: such bytes are queued instead. */
        private bool writing = false;
        private ByteArray? pending = null;

        /* Bytes the terminal answers the program with (device reports, OSC 52
         * read replies, ...). They belong on the PTY. */
        public signal void write_pty (uint8[] bytes);
        public signal void title_changed ();
        public signal void pwd_changed ();
        public signal void bell ();
        /* OSC 52 (and OSC 1337 Copy, OSC 5522) clipboard writes. */
        public signal void clipboard_write (string text);
        /* OSC 52 "?" and OSC 5522 reads. See ClipboardReply. Without a
         * handler that replies, the program is told the clipboard is empty. */
        public signal void clipboard_read_requested (ClipboardReply reply);
        /* Synchronized output (mode 2026): hold redraws while held. */
        public signal void render_hold (bool held);
        /* libghostty ran out of memory; the terminal can no longer be trusted. */
        public signal void failed ();

        public Engine (uint16 cols, uint16 rows) {
            GhosttyVt.Terminal t;
            if (!check (GhosttyVt.Terminal.create (null, out t, uint16.max (cols, 1), uint16.max (rows, 1)),
                        "ghostty_terminal_new")) {
                return;
            }
            terminal = (owned) t;

            GhosttyVt.WritePtyFn write_pty_fn = on_write_pty;
            GhosttyVt.BellFn bell_fn = on_bell;
            GhosttyVt.TitleChangedFn title_fn = on_title_changed;
            GhosttyVt.PwdChangedFn pwd_fn = on_pwd_changed;
            GhosttyVt.RenderHoldFn hold_fn = on_render_hold;
            GhosttyVt.ClipboardWriteFn clipboard_write_fn = on_clipboard_write;
            GhosttyVt.ClipboardReadFn clipboard_read_fn = on_clipboard_read;

            set_option (GhosttyVt.TerminalOption.USERDATA, (void*) this);
            set_option (GhosttyVt.TerminalOption.WRITE_PTY, (void*) write_pty_fn);
            set_option (GhosttyVt.TerminalOption.BELL, (void*) bell_fn);
            set_option (GhosttyVt.TerminalOption.TITLE_CHANGED, (void*) title_fn);
            set_option (GhosttyVt.TerminalOption.PWD_CHANGED, (void*) pwd_fn);
            set_option (GhosttyVt.TerminalOption.RENDER_HOLD, (void*) hold_fn);
            set_option (GhosttyVt.TerminalOption.CLIPBOARD_WRITE, (void*) clipboard_write_fn);
            set_option (GhosttyVt.TerminalOption.CLIPBOARD_READ, (void*) clipboard_read_fn);
        }

        /* Feeds output from the child into the terminal. */
        public void write (uint8[] bytes) {
            if (terminal == null || bytes.length == 0) {
                return;
            }
            if (writing) {
                if (pending == null) {
                    pending = new ByteArray ();
                }
                pending.append (bytes);
                return;
            }
            writing = true;
            terminal.vt_write (bytes);
            while (pending != null) {
                var queued = (owned) pending;
                pending = null;
                terminal.vt_write (queued.data);
            }
            writing = false;
        }

        /* Zero sizes are clamped to 1: libghostty rejects them. */
        public void resize (uint16 cols, uint16 rows, uint32 cell_w, uint32 cell_h) {
            if (terminal == null) {
                return;
            }
            check (terminal.resize (uint16.max (cols, 1), uint16.max (rows, 1), cell_w, cell_h),
                   "ghostty_terminal_resize");
        }

        public uint16 cols {
            get { return get_uint16 (GhosttyVt.TerminalData.COLS); }
        }

        public uint16 rows {
            get { return get_uint16 (GhosttyVt.TerminalData.ROWS); }
        }

        /* Rows above the active screen. */
        public long scrollback_rows {
            get { return (long) get_size (GhosttyVt.TerminalData.SCROLLBACK_ROWS); }
        }

        /* The absolute row at the top of the viewport. */
        public long viewport_top {
            get {
                GhosttyVt.TerminalScrollbar bar = {};
                if (terminal == null
                    || !check (terminal.get (GhosttyVt.TerminalData.SCROLLBAR, &bar), "scrollbar")) {
                    return 0;
                }
                return (long) bar.offset;
            }
        }

        /* Null until a program sets one (OSC 0/2). */
        public string? title {
            owned get { return get_string (GhosttyVt.TerminalData.TITLE); }
        }

        /* The raw OSC 7 value (normally a file:// URI); null until set. */
        public string? pwd {
            owned get { return get_string (GhosttyVt.TerminalData.PWD); }
        }

        /* The cursor's column and absolute row. */
        public void cursor (out long col, out long abs_row) {
            col = get_uint16 (GhosttyVt.TerminalData.CURSOR_X);
            abs_row = scrollback_rows + get_uint16 (GhosttyVt.TerminalData.CURSOR_Y);
        }

        /*
         * Plain text from (start_row, start_col) up to, but not including,
         * (end_row, end_col), in absolute rows. Soft-wrapped rows are joined
         * and trailing blanks trimmed, as VTE's get_text_range does. A range
         * past the end of the screen is cut short; an empty one gives "".
         */
        public string text_range (long start_row, long start_col, long end_row, long end_col) {
            if (terminal == null) {
                return "";
            }
            long ncols = cols;
            long last_row = (long) get_size (GhosttyVt.TerminalData.TOTAL_ROWS) - 1;
            start_row = long.max (start_row, 0);
            start_col = start_col.clamp (0, ncols - 1);
            if (end_row > last_row) {
                end_row = last_row;
                end_col = ncols;
            }
            end_col = long.min (end_col, ncols);
            // An exclusive end at column 0 ends at the previous row's last cell.
            if (end_col <= 0) {
                end_row--;
                end_col = ncols;
            }
            if (end_row < start_row || (end_row == start_row && end_col <= start_col)) {
                return "";
            }

            GhosttyVt.Selection selection = {};
            if (!grid_ref_at (start_row, start_col, out selection.start)
                || !grid_ref_at (end_row, end_col - 1, out selection.end)) {
                return "";
            }

            GhosttyVt.Formatter formatter;
            if (!check (GhosttyVt.Formatter.create (null, out formatter, terminal), "ghostty_formatter_terminal_new")) {
                return "";
            }
            var emit = GhosttyVt.FormatterFormat.PLAIN;
            bool yes = true;
            if (!check (formatter.set (GhosttyVt.FormatterOption.EMIT, &emit), "formatter emit")
                || !check (formatter.set (GhosttyVt.FormatterOption.UNWRAP, &yes), "formatter unwrap")
                || !check (formatter.set (GhosttyVt.FormatterOption.TRIM, &yes), "formatter trim")
                || !check (formatter.set (GhosttyVt.FormatterOption.SELECTION, &selection), "formatter selection")) {
                return "";
            }

            uint8* buf = null;
            size_t len = 0;
            if (!check (formatter.format_alloc (null, out buf, out len), "ghostty_formatter_format_alloc")) {
                return "";
            }
            var text = buffer_to_string (buf, len);
            GhosttyVt.free (null, buf, len);
            return text;
        }

        /*
         * With clear_history, a full reset (RIS): modes, screen and
         * scrollback. Without it, a soft reset (DECSTR), which resets modes,
         * attributes and margins but leaves the screen and scrollback alone.
         */
        public void reset (bool clear_history) {
            if (terminal == null) {
                return;
            }
            if (clear_history) {
                terminal.reset ();
            } else {
                write ("\x1b[!p".data);
            }
        }

        /* Moves the viewport by delta_rows; negative is up into the scrollback. */
        public void scroll_viewport (long delta_rows) {
            if (terminal == null) {
                return;
            }
            GhosttyVt.TerminalScrollViewport behavior = {};
            behavior.tag = GhosttyVt.TerminalScrollViewportTag.DELTA;
            behavior.value.delta = (intptr) delta_rows;
            check (terminal.scroll_viewport (behavior), "ghostty_terminal_scroll_viewport");
        }

        /* Whether a mode is set. `mode` is a packed GhosttyMode: the mode
         * number, with bit 15 set for an ANSI (non-DEC-private) mode. */
        public bool mode (uint16 mode) {
            if (terminal == null) {
                return false;
            }
            GhosttyVt.TerminalModeConfig config = { mode, false };
            if (terminal.get (GhosttyVt.TerminalData.MODE, &config) != GhosttyVt.Result.SUCCESS) {
                return false;
            }
            return config.value;
        }

        /* The render state, brought up to date with the terminal. Owned by
         * the Engine and reused by every call. Null only after failed (). */
        public unowned GhosttyVt.RenderState? render_state () {
            if (terminal == null) {
                return null;
            }
            if (state == null) {
                GhosttyVt.RenderState s;
                if (!check (GhosttyVt.RenderState.create (null, out s), "ghostty_render_state_new")) {
                    return null;
                }
                state = (owned) s;
            }
            if (!check (state.update (terminal), "ghostty_render_state_update")) {
                return null;
            }
            return state;
        }

        /* ---- libghostty callbacks; userdata is the Engine ---- */

        private static void on_write_pty (GhosttyVt.Terminal t, void* userdata, [CCode (type = "const uint8_t*")] uint8* data, size_t len) {
            var bytes = new uint8[len];
            Memory.copy (bytes, data, len);
            ((Engine) userdata).write_pty (bytes);
        }

        private static void on_bell (GhosttyVt.Terminal t, void* userdata) {
            ((Engine) userdata).bell ();
        }

        private static void on_title_changed (GhosttyVt.Terminal t, void* userdata) {
            ((Engine) userdata).title_changed ();
        }

        private static void on_pwd_changed (GhosttyVt.Terminal t, void* userdata) {
            ((Engine) userdata).pwd_changed ();
        }

        private static void on_render_hold (GhosttyVt.Terminal t, void* userdata, [CCode (type = "bool")] bool held) {
            ((Engine) userdata).render_hold (held);
        }

        /* Emits the first text representation; replies before returning, as
         * libghostty requires. contents_len == 0 (clear) is not supported. */
        private static void on_clipboard_write (GhosttyVt.Terminal t, void* userdata, [CCode (type = "const GhosttyClipboardWrite*")] GhosttyVt.ClipboardWrite* write) {
            string? text = null;
            for (size_t i = 0; i < write->contents_len; i++) {
                var content = write->contents[i];
                if (string_of (content.mime).has_prefix ("text/")) {
                    text = string_of (content.data).make_valid ();
                    break;
                }
            }

            GhosttyVt.ClipboardWriteReply reply = {};
            reply.size = sizeof (GhosttyVt.ClipboardWriteReply);
            reply.result = text != null
                ? GhosttyVt.ClipboardWriteResult.SUCCESS
                : GhosttyVt.ClipboardWriteResult.UNSUPPORTED;
            if (text != null) {
                ((Engine) userdata).clipboard_write (text);
            }
            write->reply (write, &reply);
        }

        private static void on_clipboard_read (GhosttyVt.Terminal t, void* userdata, [CCode (type = "const GhosttyClipboardRead*")] GhosttyVt.ClipboardRead* read) {
            // `read` is only valid until this function returns.
            bool open = true;
            ClipboardReply reply = (text) => {
                if (!open) {
                    warning ("clipboard reply after the read request ended; ignored");
                    return;
                }
                open = false;
                answer_read (read, text);
            };
            ((Engine) userdata).clipboard_read_requested (reply);
            open = false;
        }

        private static void answer_read ([CCode (type = "const GhosttyClipboardRead*")] GhosttyVt.ClipboardRead* read, string? text) {
            GhosttyVt.ClipboardReadReply reply = {};
            reply.size = sizeof (GhosttyVt.ClipboardReadReply);
            if (text == null) {
                reply.result = GhosttyVt.ClipboardReadResult.DENIED;
                read->reply (read, &reply);
                return;
            }
            unowned string mime = "text/plain";
            GhosttyVt.ClipboardContent content = {};
            content.mime = { (uint8*) mime, mime.length };
            content.data = { (uint8*) text, text.length };
            reply.result = GhosttyVt.ClipboardReadResult.SUCCESS;
            reply.contents = &content;
            reply.contents_len = 1;
            read->reply (read, &reply);
        }

        /* ---- helpers ---- */

        /* True on success. Out of memory is fatal to the terminal: critical
         * and failed (). Anything else is a bug in how Engine calls the API. */
        private bool check (GhosttyVt.Result result, string what) {
            if (result == GhosttyVt.Result.SUCCESS) {
                return true;
            }
            if (result == GhosttyVt.Result.OUT_OF_MEMORY) {
                critical ("%s: out of memory", what);
                failed ();
            } else {
                warning ("%s failed: %d", what, result);
            }
            return false;
        }

        private void set_option (GhosttyVt.TerminalOption option, void* value) {
            check (terminal.set (option, value), "ghostty_terminal_set");
        }

        private uint16 get_uint16 (GhosttyVt.TerminalData data) {
            uint16 value = 0;
            if (terminal != null) {
                check (terminal.get (data, &value), "ghostty_terminal_get");
            }
            return value;
        }

        private size_t get_size (GhosttyVt.TerminalData data) {
            size_t value = 0;
            if (terminal != null) {
                check (terminal.get (data, &value), "ghostty_terminal_get");
            }
            return value;
        }

        /* Copies a borrowed libghostty string; null when unset (empty). */
        private string? get_string (GhosttyVt.TerminalData data) {
            GhosttyVt.String value = {};
            if (terminal == null || !check (terminal.get (data, &value), "ghostty_terminal_get")
                || value.len == 0) {
                return null;
            }
            return string_of (value).make_valid ();
        }

        private bool grid_ref_at (long row, long col, out GhosttyVt.GridRef grid_ref) {
            GhosttyVt.Point point = {};
            point.tag = GhosttyVt.PointTag.SCREEN;
            point.value.coordinate.x = (uint16) col;
            point.value.coordinate.y = (uint32) row;
            // INVALID_VALUE here just means out of range.
            return terminal.grid_ref (point, out grid_ref) == GhosttyVt.Result.SUCCESS;
        }

        private static string string_of (GhosttyVt.String s) {
            return buffer_to_string (s.ptr, s.len);
        }

        private static string buffer_to_string (uint8* ptr, size_t len) {
            if (ptr == null || len == 0) {
                return "";
            }
            // Binary-safe copy; text after an embedded NUL is unreachable
            // from a C string either way.
            var copy = new StringBuilder.sized (len + 1);
            copy.append_len ((string) ptr, (ssize_t) len);
            return (owned) copy.str;
        }
    }
}
