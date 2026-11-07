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

    /* How much of the frame changed since the last render_clean (). */
    internal enum RenderDirty { CLEAN, PARTIAL, FULL }

    /* The cursor shape to draw, which a program may have chosen (DECSCUSR). */
    internal enum RenderCursor { BLOCK, BAR, UNDERLINE, BLOCK_HOLLOW }

    /* NARROW takes one cell, WIDE two; a SPACER is the cell a WIDE one
     * covers (or reserves at a line end) and draws no text. */
    internal enum CellWidth { NARROW, WIDE, SPACER }

    /* Engine.cell_flags () bits (GHOSTTY_STYLE_FLAG_*). */
    [Flags]
    internal enum CellFlag {
        BOLD = 1 << 0,
        ITALIC = 1 << 1,
        FAINT = 1 << 2,
        BLINK = 1 << 3,
        INVERSE = 1 << 4,
        INVISIBLE = 1 << 5,
        STRIKETHROUGH = 1 << 6,
        OVERLINE = 1 << 7,
        UNDERLINE = 7 << 8
    }

    internal class Engine : Object {
        private GhosttyVt.Terminal? terminal = null;
        private GhosttyVt.RenderState? state = null;
        private GhosttyVt.RenderStateRowIterator? row_iter = null;
        private GhosttyVt.RenderStateRowCells? cell_iter = null;

        /* Guards against re-entering vt_write from a signal handler, which
         * libghostty does not support: such bytes are queued instead. */
        private bool writing = false;
        /* Set by on_reset, so reset (true) knows whether libghostty already
         * reported its own reset. */
        private bool reset_reported = false;
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
         * handler that replies, the program is told the clipboard is empty.
         * granted is libghostty's flag: true when the user already allowed
         * this read, as for the follow-up read of a Kitty paste event (mode
         * 5522, enabled because this callback is installed); always false for
         * OSC 52. Only text/plain is answered. */
        public signal void clipboard_read_requested (bool granted, ClipboardReply reply);
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
            GhosttyVt.ResetFn reset_fn = on_reset;
            GhosttyVt.ClipboardWriteFn clipboard_write_fn = on_clipboard_write;
            GhosttyVt.ClipboardReadFn clipboard_read_fn = on_clipboard_read;

            set_option (GhosttyVt.TerminalOption.USERDATA, (void*) this);
            set_option (GhosttyVt.TerminalOption.WRITE_PTY, (void*) write_pty_fn);
            set_option (GhosttyVt.TerminalOption.BELL, (void*) bell_fn);
            set_option (GhosttyVt.TerminalOption.TITLE_CHANGED, (void*) title_fn);
            set_option (GhosttyVt.TerminalOption.PWD_CHANGED, (void*) pwd_fn);
            set_option (GhosttyVt.TerminalOption.RENDER_HOLD, (void*) hold_fn);
            set_option (GhosttyVt.TerminalOption.RESET, (void*) reset_fn);
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
            // Signals fire inside vt_write; a handler may drop the last
            // reference to this Engine, which must not free the terminal
            // mid-parse.
            Engine keep_alive = this;
            writing = true;
            terminal.vt_write (bytes);
            while (pending != null) {
                var queued = (owned) pending;
                pending = null;
                terminal.vt_write (queued.data);
            }
            writing = false;
            keep_alive = null;
        }

        /* Zero sizes are clamped to 1: libghostty rejects them. */
        public void resize (uint16 cols, uint16 rows, uint32 cell_w, uint32 cell_h) {
            if (terminal == null) {
                return;
            }
            // render_hold may fire inside; see write ().
            Engine keep_alive = this;
            check (terminal.resize (uint16.max (cols, 1), uint16.max (rows, 1), cell_w, cell_h),
                   "ghostty_terminal_resize");
            keep_alive = null;
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
                // render_hold and the reset signals fire inside; see write ().
                Engine keep_alive = this;
                reset_reported = false;
                terminal.reset ();
                // RIS clears the title and pwd without TITLE_CHANGED or
                // PWD_CHANGED; on_reset reports that, unless libghostty only
                // calls it for a program's RIS.
                if (!reset_reported) {
                    emit_reset ();
                }
                keep_alive = null;
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

        /* ---- options ---- */

        /* Default colors as 0xRRGGBB; a negative value restores libghostty's. */
        public void set_foreground (int rgb) {
            set_color_option (GhosttyVt.TerminalOption.COLOR_FOREGROUND, rgb);
        }

        public void set_background (int rgb) {
            set_color_option (GhosttyVt.TerminalOption.COLOR_BACKGROUND, rgb);
        }

        public void set_cursor_color (int rgb) {
            set_color_option (GhosttyVt.TerminalOption.COLOR_CURSOR, rgb);
        }

        /* The first colors.length palette entries (0xRRGGBB); the rest, or
         * all of them for null, are libghostty's built-in palette. */
        public void set_palette (uint32[]? colors) {
            if (terminal == null) {
                return;
            }
            var palette = new GhosttyVt.ColorRgb[256];
            GhosttyVt.color_palette_default (palette);
            for (var i = 0; colors != null && i < colors.length && i < 256; i++) {
                palette[i] = to_rgb (colors[i]);
            }
            set_option (GhosttyVt.TerminalOption.COLOR_PALETTE, (void*) palette);
        }

        /* The cursor shape a program gets until it sets its own (DECSCUSR),
         * and again after it resets it. Applies at once to a default cursor. */
        public void set_cursor_shape (CursorShape shape) {
            if (terminal == null) {
                return;
            }
            GhosttyVt.CursorStyle style;
            switch (shape) {
            case CursorShape.IBEAM:
                style = GhosttyVt.CursorStyle.BAR;
                break;
            case CursorShape.UNDERLINE:
                style = GhosttyVt.CursorStyle.UNDERLINE;
                break;
            default:
                style = GhosttyVt.CursorStyle.BLOCK;
                break;
            }
            set_option (GhosttyVt.TerminalOption.DEFAULT_CURSOR_STYLE, &style);
        }

        /* Scrollback limited by lines only, as VTE's is: libghostty's
         * default byte limit (about one page) is lifted. size_t.MAX means
         * unlimited. */
        public void set_scrollback_lines (size_t lines) {
            if (terminal == null) {
                return;
            }
            size_t unlimited = size_t.MAX;
            set_option (GhosttyVt.TerminalOption.SCROLLBACK_MAX_BYTES, &unlimited);
            set_option (GhosttyVt.TerminalOption.SCROLLBACK_MAX_LINES, &lines);
        }

        /* ---- rendering ----
         *
         * A frame is read in this order: render_begin (), render_colors (),
         * render_cursor (), then rows_begin () and, for each rows_next (),
         * the row_* accessors; row_cells () positions the cell accessors on
         * that row. render_clean () ends a frame that was drawn completely.
         * Everything read is valid only until the next render_begin ().
         */

        /* Synchronized output (mode 2026). While held, render_begin () keeps
         * the frame captured when the hold started. */
        public bool held { get; private set; default = false; }

        /* Brings the render state up to date, unless a render hold is on.
         * False only after failed (). */
        public bool render_begin (out RenderDirty dirty) {
            dirty = RenderDirty.FULL;
            if (!ensure_render_state ()) {
                return false;
            }
            if (!held && !check (state.update (terminal), "ghostty_render_state_update")) {
                return false;
            }
            var d = GhosttyVt.RenderStateDirty.FULL;
            check (state.get (GhosttyVt.RenderStateData.DIRTY, &d), "render dirty");
            switch (d) {
            case GhosttyVt.RenderStateDirty.FALSE:
                dirty = RenderDirty.CLEAN;
                break;
            case GhosttyVt.RenderStateDirty.PARTIAL:
                dirty = RenderDirty.PARTIAL;
                break;
            default:
                dirty = RenderDirty.FULL;
                break;
            }
            return true;
        }

        /* The default colors in effect (set_* or OSC 10/11/12), 0xRRGGBB.
         * has_cursor is false when no cursor color is set. */
        public void render_colors (out uint32 foreground, out uint32 background,
                                   out bool has_cursor, out uint32 cursor) {
            GhosttyVt.RenderStateColors colors = {};
            colors.size = sizeof (GhosttyVt.RenderStateColors);
            check (state.get (GhosttyVt.RenderStateData.COLORS, &colors), "render colors");
            foreground = from_rgb (colors.foreground);
            background = from_rgb (colors.background);
            has_cursor = colors.cursor_has_value;
            cursor = has_cursor ? from_rgb (colors.cursor) : 0;
        }

        /* The cursor's viewport cell and shape; false when it is hidden or
         * outside the viewport. x is moved off a wide character's tail. */
        public bool render_cursor (out uint16 x, out uint16 y, out RenderCursor style) {
            x = 0;
            y = 0;
            style = RenderCursor.BLOCK;
            GhosttyVt.RenderStateCursor cursor = {};
            cursor.size = sizeof (GhosttyVt.RenderStateCursor);
            if (!check (state.get (GhosttyVt.RenderStateData.CURSOR, &cursor), "render cursor")
                || !cursor.visible || !cursor.viewport_has_value) {
                return false;
            }
            x = cursor.viewport_x;
            if (cursor.wide_tail && x > 0) {
                x--;
            }
            y = cursor.viewport_y;
            switch (cursor.visual_style) {
            case GhosttyVt.CursorStyle.BAR:
                style = RenderCursor.BAR;
                break;
            case GhosttyVt.CursorStyle.UNDERLINE:
                style = RenderCursor.UNDERLINE;
                break;
            case GhosttyVt.CursorStyle.BLOCK_HOLLOW:
                style = RenderCursor.BLOCK_HOLLOW;
                break;
            default:
                style = RenderCursor.BLOCK;
                break;
            }
            return true;
        }

        /* Marks the frame drawn: clears the global and per-row dirty flags. */
        public void render_clean () {
            if (state != null) {
                check (state.clean (), "ghostty_render_state_clean");
            }
        }

        /* Starts walking the viewport's rows, top to bottom. */
        public bool rows_begin () {
            if (state == null) {
                return false;
            }
            if (row_iter == null) {
                GhosttyVt.RenderStateRowIterator it;
                if (!check (GhosttyVt.RenderStateRowIterator.create (null, out it), "row iterator")) {
                    return false;
                }
                row_iter = (owned) it;
            }
            return check (state.get (GhosttyVt.RenderStateData.ROW_ITERATOR, &row_iter), "row iterator");
        }

        /* Moves to the next row; y is its viewport row. */
        public bool rows_next (out int y) {
            y = 0;
            if (row_iter == null || !row_iter.next ()) {
                return false;
            }
            int32 viewport_y = 0;
            check (row_iter.get (GhosttyVt.RenderStateRowData.VIEWPORT_Y, &viewport_y), "row y");
            y = viewport_y;
            return true;
        }

        /* The row's identity across frames, as a hash key. */
        public string row_key () {
            GhosttyVt.RenderStateRowId id = {};
            check (row_iter.get (GhosttyVt.RenderStateRowData.ID, &id), "row id");
            return "%s.%s".printf (id.bits[0].to_string (), id.bits[1].to_string ());
        }

        /* Whether the row changed since the last render_clean (). */
        public bool row_dirty () {
            bool dirty = true;
            check (row_iter.get (GhosttyVt.RenderStateRowData.DIRTY, &dirty), "row dirty");
            return dirty;
        }

        /* The selected columns of this row, inclusive; false if none. */
        public bool row_selection (out uint16 start, out uint16 end) {
            GhosttyVt.RenderStateRowSelection sel = {};
            sel.size = sizeof (GhosttyVt.RenderStateRowSelection);
            var result = row_iter.get (GhosttyVt.RenderStateRowData.SELECTION, &sel);
            start = sel.start_x;
            end = sel.end_x;
            return result == GhosttyVt.Result.SUCCESS;
        }

        /* Positions the cell accessors before this row's first cell. */
        public bool row_cells () {
            if (cell_iter == null) {
                GhosttyVt.RenderStateRowCells c;
                if (!check (GhosttyVt.RenderStateRowCells.create (null, out c), "row cells")) {
                    return false;
                }
                cell_iter = (owned) c;
            }
            return check (row_iter.get (GhosttyVt.RenderStateRowData.CELLS, &cell_iter), "row cells");
        }

        public bool cells_next () {
            return cell_iter.next ();
        }

        public bool cells_select (uint16 x) {
            return cell_iter.select (x) == GhosttyVt.Result.SUCCESS;
        }

        /* The cell's grapheme cluster as UTF-8; null for an empty cell. */
        public string? cell_text () {
            uint8 small[32];
            GhosttyVt.Buffer buf = { small, small.length, 0 };
            var result = cell_iter.get (GhosttyVt.RenderStateRowCellsData.GRAPHEMES_UTF8, &buf);
            uint8[]? large = null;
            if (result == GhosttyVt.Result.OUT_OF_SPACE) {
                large = new uint8[buf.len];
                buf = { large, large.length, 0 };
                result = cell_iter.get (GhosttyVt.RenderStateRowCellsData.GRAPHEMES_UTF8, &buf);
            }
            if (result != GhosttyVt.Result.SUCCESS || buf.len == 0) {
                return null;
            }
            return buffer_to_string (buf.ptr, buf.len).make_valid ();
        }

        /* GHOSTTY_STYLE_FLAG_* bits, see CellFlag. */
        public uint16 cell_flags () {
            GhosttyVt.Style style = {};
            check (cell_iter.get (GhosttyVt.RenderStateRowCellsData.STYLE, &style), "cell style");
            return style.flags;
        }

        /* The cell's own resolved colors; false means the default. */
        public bool cell_foreground (out uint32 rgb) {
            return cell_color (GhosttyVt.RenderStateRowCellsData.FG_COLOR, out rgb);
        }

        public bool cell_background (out uint32 rgb) {
            return cell_color (GhosttyVt.RenderStateRowCellsData.BG_COLOR, out rgb);
        }

        public CellWidth cell_width () {
            uint64 raw = 0;
            check (cell_iter.get (GhosttyVt.RenderStateRowCellsData.RAW, &raw), "cell raw");
            var wide = GhosttyVt.CellWide.NARROW;
            check (GhosttyVt.cell_get (raw, GhosttyVt.CellData.WIDE, &wide), "cell wide");
            switch (wide) {
            case GhosttyVt.CellWide.WIDE:
                return CellWidth.WIDE;
            case GhosttyVt.CellWide.SPACER_TAIL:
            case GhosttyVt.CellWide.SPACER_HEAD:
                return CellWidth.SPACER;
            default:
                return CellWidth.NARROW;
            }
        }

        private bool cell_color (GhosttyVt.RenderStateRowCellsData which, out uint32 rgb) {
            GhosttyVt.ColorRgb color = {};
            var result = cell_iter.get (which, &color);
            rgb = from_rgb (color);
            return result == GhosttyVt.Result.SUCCESS;
        }

        private bool ensure_render_state () {
            if (terminal == null) {
                return false;
            }
            if (state == null) {
                GhosttyVt.RenderState s;
                if (!check (GhosttyVt.RenderState.create (null, out s), "ghostty_render_state_new")) {
                    return false;
                }
                state = (owned) s;
            }
            return true;
        }

        /* Ends a hold the program has kept too long, by turning mode 2026
         * off; libghostty does not report that, so held is cleared here. */
        public void release_hold () {
            if (terminal != null && held) {
                GhosttyVt.TerminalModeConfig config = { 2026, false };
                check (terminal.set (GhosttyVt.TerminalOption.MODE, &config), "release hold");
            }
            held = false;
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

        /* A full reset (RIS) cleared the title and pwd; libghostty does not
         * call TITLE_CHANGED or PWD_CHANGED for that. */
        private static void on_reset (GhosttyVt.Terminal t, void* userdata) {
            ((Engine) userdata).emit_reset ();
        }

        private void emit_reset () {
            reset_reported = true;
            title_changed ();
            pwd_changed ();
        }

        /* A hold starts with the screen exactly as the program wants it left,
         * so that frame is captured now (libghostty allows a render state
         * update from inside vt_write), and kept until the hold ends. */
        private static void on_render_hold (GhosttyVt.Terminal t, void* userdata, [CCode (type = "bool")] bool held) {
            var self = (Engine) userdata;
            if (held && self.ensure_render_state ()) {
                self.check (self.state.update (t), "ghostty_render_state_update");
            }
            self.held = held;
            self.render_hold (held);
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
            ((Engine) userdata).clipboard_read_requested (read->granted, reply);
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

        private void set_color_option (GhosttyVt.TerminalOption option, int rgb) {
            if (terminal == null) {
                return;
            }
            if (rgb < 0) {
                set_option (option, null);
                return;
            }
            var color = to_rgb ((uint32) rgb);
            set_option (option, &color);
        }

        private static GhosttyVt.ColorRgb to_rgb (uint32 rgb) {
            return { (uint8) (rgb >> 16), (uint8) (rgb >> 8), (uint8) rgb };
        }

        private static uint32 from_rgb (GhosttyVt.ColorRgb c) {
            return ((uint32) c.r << 16) | ((uint32) c.g << 8) | c.b;
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
