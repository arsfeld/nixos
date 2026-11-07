/*
 * Terminal: the widget, with VTE 0.84's API (only what elementary uses).
 *
 * Output: Pty.data -> process_output () -> Engine.write (), then at most one
 * redraw per frame clock tick, through a single pending tick callback; no
 * redraw is queued while the program holds rendering (mode 2026), and a hold
 * longer than HOLD_TIMEOUT_MS is ended here. contents_changed fires once per
 * tick that processed output.
 *
 * Size: the allocation in whole cells, never less than 1x1, goes to
 * Engine.resize () and Pty.set_size ().
 *
 * Scrolling: Gtk.Scrollable. The vadjustment counts rows: upper is
 * scrollback plus screen rows, page_size the screen rows, value the
 * viewport's top row; moving it scrolls the viewport. hadjustment is kept
 * and unused.
 */
namespace Gvt {
    public class Terminal : Gtk.Widget, Gtk.Scrollable {
        private const int HOLD_TIMEOUT_MS = 1000;
        private const string DEFAULT_FONT = "Monospace 10";

        internal Engine engine;
        internal Renderer renderer;

        private Pty? pty = null;
        private bool exit_reported = false;
        private string? title = null;

        private uint tick_id = 0;
        private uint idle_id = 0;
        private uint hold_timeout_id = 0;
        private bool output_pending = false;

        private bool allocated = false;
        /* The cell size the engine was last resized with. */
        private int sized_cell_w = 0;
        private int sized_cell_h = 0;
        private Pango.FontDescription base_font;
        private double scale = 1.0;
        private uint scrollback = 512;

        private Gtk.Adjustment? vadj = null;
        private Gtk.Adjustment? hadj = null;
        private ulong vadj_handler = 0;
        private bool syncing_adjustment = false;

        /* ---- properties ---- */

        public double font_scale {
            get { return scale; }
            set {
                var clamped = value.clamp (0.25, 4.0);
                if (clamped == scale) {
                    return;
                }
                scale = clamped;
                apply_font ();
            }
        }

        public uint scrollback_lines {
            get { return scrollback; }
            set {
                scrollback = value;
                engine.set_scrollback_lines (value == uint.MAX ? size_t.MAX : (size_t) value);
                sync_adjustment ();
            }
        }

        public bool audible_bell { get; set; default = true; }
        public bool pointer_autohide { get; set; default = false; }
        public bool enable_fallback_scrolling { get; set; default = true; }
        /* Stored only: the vadjustment always counts rows. */
        public bool scroll_unit_is_pixels { get; set; default = false; }

        public string window_title {
            get { return title; }
        }

        public Gtk.Adjustment hadjustment {
            get { return hadj; }
            set construct {
                hadj = value ?? new Gtk.Adjustment (0, 0, 0, 0, 0, 0);
            }
        }

        public Gtk.Adjustment vadjustment {
            get { return vadj; }
            set construct {
                if (vadj != null && vadj_handler != 0) {
                    vadj.disconnect (vadj_handler);
                }
                vadj = value ?? new Gtk.Adjustment (0, 0, 0, 0, 0, 0);
                vadj_handler = vadj.value_changed.connect (on_vadjustment_changed);
                sync_adjustment ();
            }
        }

        public Gtk.ScrollablePolicy hscroll_policy { get; set; }
        public Gtk.ScrollablePolicy vscroll_policy { get; set; }

        /* ---- signals ---- */

        public virtual signal void bell () {
        }

        /* The raw wait status, as VTE passes it; -1 if the terminal failed. */
        public virtual signal void child_exited (int status) {
        }

        public virtual signal void contents_changed () {
        }

        public virtual signal void window_title_changed () {
        }

        [Signal (action = true)]
        public virtual signal void increase_font_size () {
            font_scale = font_scale * 1.2;
        }

        [Signal (action = true)]
        public virtual signal void decrease_font_size () {
            font_scale = font_scale / 1.2;
        }

        construct {
            engine = new Engine (80, 24);
            engine.set_scrollback_lines (scrollback);
            engine.write_pty.connect (on_engine_reply);
            engine.title_changed.connect (on_title_changed);
            engine.bell.connect (on_bell);
            engine.render_hold.connect (on_render_hold);
            engine.failed.connect (on_engine_failed);

            base_font = Pango.FontDescription.from_string (DEFAULT_FONT);
            renderer = new Renderer (this);
            apply_font ();

            focusable = true;
            overflow = Gtk.Overflow.HIDDEN;
            sync_adjustment ();
        }

        public Terminal () {
        }

        public override void dispose () {
            if (pty != null) {
                pty.close ();
                pty = null;
            }
            if (tick_id != 0) {
                remove_tick_callback (tick_id);
                tick_id = 0;
            }
            remove_source (ref idle_id);
            remove_source (ref hold_timeout_id);
            if (vadj != null && vadj_handler != 0) {
                vadj.disconnect (vadj_handler);
                vadj_handler = 0;
            }
            base.dispose ();
        }

        /* ---- the child ---- */

        public void spawn_async (PtyFlags pty_flags, string? working_directory, string[] argv,
                                 string[]? envv, SpawnFlags spawn_flags,
                                 owned SpawnChildSetupFunc? child_setup, int timeout,
                                 Cancellable? cancellable,
                                 owned TerminalSpawnAsyncCallback? callback) {
            Pid pid = -1;
            Error? error = null;
            try {
                if (cancellable != null) {
                    cancellable.set_error_if_cancelled ();
                }
                // The child starts at the current size, before the program
                // can ask for it.
                var ws = GvtPosix.WinSize () {
                    ws_col = engine.cols, ws_row = engine.rows,
                    ws_xpixel = (uint16) (engine.cols * get_char_width ()),
                    ws_ypixel = (uint16) (engine.rows * get_char_height ())
                };
                SpawnChildSetupFunc? setup = (owned) child_setup;
                var spawned = Pty.spawn (working_directory, argv, envv, spawn_flags, () => {
                    GvtPosix.ioctl_winsize (0, GvtPosix.TIOCSWINSZ, ref ws);
                    if (setup != null) {
                        setup ();
                    }
                }, out pid);
                attach_pty (spawned);
            } catch (Error e) {
                error = e;
                pid = -1;
            }
            if (callback != null) {
                TerminalSpawnAsyncCallback cb = (owned) callback;
                Idle.add (() => {
                    cb (this, pid, error);
                    return Source.REMOVE;
                });
            }
        }

        private void attach_pty (Pty spawned) {
            if (pty != null) {
                pty.close ();
            }
            pty = spawned;
            exit_reported = false;
            pty.data.connect (process_output);
            pty.exited.connect (on_child_exited);
        }

        public unowned Pty? get_pty () {
            return pty;
        }

        /* Sends bytes to the child as if typed. */
        public void feed_child (uint8[]? text) {
            if (pty != null && text != null) {
                pty.write (text);
            }
        }

        /* The child's output: everything Pty reads comes through here. */
        internal void process_output (uint8[] chunk) {
            engine.write (chunk);
            output_pending = true;
            schedule_frame ();
        }

        private void on_engine_reply (uint8[] bytes) {
            if (pty != null) {
                pty.write (bytes);
            }
        }

        private void on_child_exited (int status) {
            report_exit (status);
        }

        private void report_exit (int status) {
            if (exit_reported) {
                return;
            }
            exit_reported = true;
            child_exited (status);
        }

        /* libghostty ran out of memory: hang up the child and report it gone,
         * which closes the tab in elementary. */
        private void on_engine_failed () {
            if (pty != null) {
                pty.close ();
                pty = null;
            }
            report_exit (-1);
        }

        /* ---- engine events ---- */

        private void on_title_changed () {
            title = engine.title;
            notify_property ("window-title");
            window_title_changed ();
        }

        private void on_bell () {
            if (audible_bell) {
                get_display ().beep ();
            }
            bell ();
        }

        private void on_render_hold (bool held) {
            remove_source (ref hold_timeout_id);
            if (held) {
                hold_timeout_id = Timeout.add (HOLD_TIMEOUT_MS, () => {
                    hold_timeout_id = 0;
                    engine.release_hold ();
                    queue_draw ();
                    return Source.REMOVE;
                });
            } else {
                queue_draw ();
            }
        }

        /* ---- one redraw per frame ---- */

        private void schedule_frame () {
            if (tick_id != 0 || idle_id != 0) {
                return;
            }
            // Without a frame clock (not realized), the next idle stands in.
            if (get_realized ()) {
                tick_id = add_tick_callback (on_tick);
            } else {
                idle_id = Idle.add (on_idle);
            }
        }

        private bool on_tick (Gtk.Widget widget, Gdk.FrameClock clock) {
            tick_id = 0;
            flush_output ();
            return Source.REMOVE;
        }

        private bool on_idle () {
            idle_id = 0;
            flush_output ();
            return Source.REMOVE;
        }

        public override void unrealize () {
            if (tick_id != 0) {
                remove_tick_callback (tick_id);
                tick_id = 0;
                schedule_frame ();
            }
            base.unrealize ();
        }

        private void flush_output () {
            if (!output_pending) {
                return;
            }
            output_pending = false;
            renderer_changed ();
            contents_changed ();
        }

        /* The screen may look different: update the scrollbar and redraw,
         * unless the program holds rendering. */
        private void renderer_changed () {
            sync_adjustment ();
            if (!engine.held) {
                queue_draw ();
            }
        }

        /* ---- size and drawing ---- */

        public override Gtk.SizeRequestMode get_request_mode () {
            return Gtk.SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure (Gtk.Orientation orientation, int for_size,
                                      out int minimum, out int natural,
                                      out int minimum_baseline, out int natural_baseline) {
            int w, h;
            renderer.cell_size (out w, out h);
            var cell = orientation == Gtk.Orientation.HORIZONTAL ? w : h;
            minimum = cell;
            natural = cell * (orientation == Gtk.Orientation.HORIZONTAL ? 80 : 24);
            minimum_baseline = -1;
            natural_baseline = -1;
        }

        public override void size_allocate (int width, int height, int baseline) {
            allocated = true;
            apply_size (width, height);
        }

        private void apply_size (int width, int height) {
            int w, h;
            renderer.cell_size (out w, out h);
            var cols = (uint16) (width / w).clamp (1, uint16.MAX);
            var rows = (uint16) (height / h).clamp (1, uint16.MAX);
            if (cols == engine.cols && rows == engine.rows && w == sized_cell_w && h == sized_cell_h) {
                return;
            }
            sized_cell_w = w;
            sized_cell_h = h;
            engine.resize (cols, rows, w, h);
            if (pty != null) {
                pty.set_size (cols, rows, (uint16) (cols * w).clamp (0, uint16.MAX),
                              (uint16) (rows * h).clamp (0, uint16.MAX));
            }
            renderer_changed ();
        }

        public override void snapshot (Gtk.Snapshot snapshot) {
            renderer.snapshot (snapshot, get_width (), get_height ());
        }

        /* ---- scrolling ---- */

        public bool get_border (out Gtk.Border border) {
            border = {};
            return false;
        }

        private void sync_adjustment () {
            if (vadj == null || engine == null) {
                return;
            }
            syncing_adjustment = true;
            double rows = engine.rows;
            vadj.configure (engine.viewport_top, 0, engine.scrollback_rows + rows, 1, rows, rows);
            syncing_adjustment = false;
        }

        private void on_vadjustment_changed () {
            if (syncing_adjustment) {
                return;
            }
            var delta = (long) Math.round (vadj.value) - engine.viewport_top;
            if (delta != 0) {
                engine.scroll_viewport (delta);
                renderer_changed ();
            }
        }

        /* ---- text and cursor ---- */

        /* (column, absolute row), rows counting from the oldest scrollback row. */
        public void get_cursor_position (out long column, out long row) {
            engine.cursor (out column, out row);
        }

        /* Text from (start_row, start_col) up to, not including, (end_row,
         * end_col). HTML is not supported and gives null. */
        public string? get_text_range_format (Format format, long start_row, long start_col,
                                              long end_row, long end_col, out size_t length) {
            length = 0;
            if (format != Format.TEXT) {
                return null;
            }
            var text = engine.text_range (start_row, start_col, end_row, end_col);
            length = text.length;
            return text;
        }

        /* With clear_history, a full reset (RIS) that also clears the
         * scrollback. Without it, a soft reset (DECSTR): libghostty's full
         * reset always clears the scrollback. Tab stops are reset either way. */
        public void reset (bool clear_tabstops, bool clear_history) {
            engine.reset (clear_history);
            renderer.invalidate ();
            renderer_changed ();
        }

        /* ---- fonts and colors ---- */

        public long get_char_width () {
            int w, h;
            renderer.cell_size (out w, out h);
            return w;
        }

        public long get_char_height () {
            int w, h;
            renderer.cell_size (out w, out h);
            return h;
        }

        public void set_font (Pango.FontDescription? font_desc) {
            base_font = font_desc != null
                ? font_desc.copy ()
                : Pango.FontDescription.from_string (DEFAULT_FONT);
            apply_font ();
        }

        private void apply_font () {
            var font = base_font.copy ();
            var size = base_font.get_size ();
            if (size <= 0) {
                size = 10 * Pango.SCALE;
            }
            var scaled = (int) Math.round (size * scale);
            if (base_font.get_size_is_absolute ()) {
                font.set_absolute_size (scaled);
            } else {
                font.set_size (scaled);
            }
            renderer.set_font (font);
            if (allocated) {
                apply_size (get_width (), get_height ());
            }
            queue_resize ();
        }

        /* VTE's rules: a null foreground is palette[7] and a null background
         * palette[0] when a palette is given, else the defaults; the palette
         * may have 0, 8, 16, 232 or 256 entries, the rest staying default.
         * The background's alpha applies to the default background. */
        public void set_colors (Gdk.RGBA? foreground, Gdk.RGBA? background, Gdk.RGBA[]? palette) {
            uint32[]? colors = null;
            if (palette != null && palette.length > 0) {
                colors = new uint32[palette.length];
                for (var i = 0; i < palette.length; i++) {
                    colors[i] = to_rgb (palette[i]);
                }
            }
            engine.set_palette (colors);

            if (foreground != null) {
                engine.set_foreground ((int) to_rgb (foreground));
            } else {
                engine.set_foreground (colors != null && colors.length > 7 ? (int) colors[7] : -1);
            }
            if (background != null) {
                engine.set_background ((int) to_rgb (background));
                renderer.background_alpha = background.alpha;
            } else {
                engine.set_background (colors != null ? (int) colors[0] : -1);
                renderer.background_alpha = 1.0;
            }
            renderer.invalidate ();
            queue_draw ();
        }

        public void set_color_cursor (Gdk.RGBA? cursor_background) {
            engine.set_cursor_color (cursor_background != null ? (int) to_rgb (cursor_background) : -1);
            queue_draw ();
        }

        public void set_cursor_shape (CursorShape shape) {
            engine.set_cursor_shape (shape);
            queue_draw ();
        }

        private static uint32 to_rgb (Gdk.RGBA c) {
            return ((uint32) Math.round (c.red.clamp (0, 1) * 255) << 16)
                   | ((uint32) Math.round (c.green.clamp (0, 1) * 255) << 8)
                   | (uint32) Math.round (c.blue.clamp (0, 1) * 255);
        }

        private static void remove_source (ref uint id) {
            if (id != 0) {
                Source.remove (id);
                id = 0;
            }
        }
    }
}
