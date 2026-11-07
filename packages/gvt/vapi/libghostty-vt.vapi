/* Handwritten binding for libghostty-vt 1.0.0 (<ghostty/vt.h>).
 *
 * Covers only what src/Engine.vala uses; Engine is the only code that may
 * use it. Add symbols here as Engine needs them, copying the C names exactly.
 * Value structs are bound field for field and must match the header layout.
 */
[CCode (cheader_filename = "ghostty/vt.h", lower_case_cprefix = "ghostty_", cprefix = "Ghostty")]
namespace GhosttyVt {
    [CCode (cname = "GhosttyResult", cprefix = "GHOSTTY_", has_type_id = false)]
    public enum Result {
        SUCCESS,
        OUT_OF_MEMORY,
        INVALID_VALUE,
        OUT_OF_SPACE,
        NO_VALUE,
        IO_ERROR,
        LIMIT_EXCEEDED,
        REJECTED,
        UNSUPPORTED
    }

    /* A borrowed byte string; not NUL-terminated. */
    [CCode (cname = "GhosttyString", has_type_id = false)]
    public struct String {
        public uint8* ptr;
        public size_t len;
    }

    /* Frees memory the library allocated (e.g. ghostty_formatter_format_alloc). */
    [CCode (cname = "ghostty_free")]
    public static void free (void* allocator, uint8* ptr, size_t len);

    /* ---- Points, grid references, selections ---- */

    [CCode (cname = "GhosttyPointTag", cprefix = "GHOSTTY_POINT_TAG_", has_type_id = false)]
    public enum PointTag {
        ACTIVE,
        VIEWPORT,
        SCREEN,
        HISTORY
    }

    [CCode (cname = "GhosttyPointCoordinate", has_type_id = false)]
    public struct PointCoordinate {
        public uint16 x;
        public uint32 y;
    }

    /* A C union; only the coordinate member is bound. */
    [CCode (cname = "GhosttyPointValue", has_type_id = false)]
    public struct PointValue {
        public PointCoordinate coordinate;
    }

    [CCode (cname = "GhosttyPoint", has_type_id = false)]
    [SimpleType]
    public struct Point {
        public PointTag tag;
        public PointValue value;
    }

    [CCode (cname = "GhosttyGridRef", has_type_id = false)]
    public struct GridRef {
        public void* node;
        public uint16 x;
        public uint16 y;
    }

    [CCode (cname = "GhosttySelection", has_type_id = false)]
    public struct Selection {
        public GridRef start;
        public GridRef end;
        public bool rectangle;
    }

    /* ---- Terminal ---- */

    [CCode (cname = "GhosttyTerminalOption", cprefix = "GHOSTTY_TERMINAL_OPT_", has_type_id = false)]
    public enum TerminalOption {
        USERDATA,
        WRITE_PTY,
        BELL,
        TITLE_CHANGED,
        PWD_CHANGED,
        CLIPBOARD_WRITE,
        CLIPBOARD_READ,
        RENDER_HOLD
    }

    [CCode (cname = "GhosttyTerminalData", cprefix = "GHOSTTY_TERMINAL_DATA_", has_type_id = false)]
    public enum TerminalData {
        COLS,
        ROWS,
        CURSOR_X,
        CURSOR_Y,
        SCROLLBAR,
        TITLE,
        PWD,
        TOTAL_ROWS,
        SCROLLBACK_ROWS,
        MODE
    }

    [CCode (cname = "GhosttyTerminalScrollbar", has_type_id = false)]
    public struct TerminalScrollbar {
        public uint64 total;
        public uint64 offset;
        public uint64 len;
    }

    [CCode (cname = "GhosttyTerminalModeConfig", has_type_id = false)]
    public struct TerminalModeConfig {
        /* A packed GhosttyMode: value in bits 0-14, bit 15 set for ANSI modes. */
        public uint16 mode;
        public bool value;
    }

    [CCode (cname = "GhosttyTerminalScrollViewportTag", cprefix = "GHOSTTY_TERMINAL_SCROLL_VIEWPORT_", has_type_id = false)]
    public enum TerminalScrollViewportTag {
        TOP,
        BOTTOM,
        DELTA,
        ROW,
        DELTA_PROMPT
    }

    /* A C union; only the delta member is bound. */
    [CCode (cname = "GhosttyTerminalScrollViewportValue", has_type_id = false)]
    public struct TerminalScrollViewportValue {
        public intptr delta;
    }

    [CCode (cname = "GhosttyTerminalScrollViewport", has_type_id = false)]
    [SimpleType]
    public struct TerminalScrollViewport {
        public TerminalScrollViewportTag tag;
        public TerminalScrollViewportValue value;
    }

    /* Callbacks. All get the GHOSTTY_TERMINAL_OPT_USERDATA pointer, run
     * synchronously inside vt_write, and must not call vt_write. Pass them to
     * Terminal.set cast to void*. */
    [CCode (cname = "GhosttyTerminalWritePtyFn", has_target = false)]
    public delegate void WritePtyFn (Terminal terminal, void* userdata, [CCode (type = "const uint8_t*")] uint8* data, size_t len);
    [CCode (cname = "GhosttyTerminalBellFn", has_target = false)]
    public delegate void BellFn (Terminal terminal, void* userdata);
    [CCode (cname = "GhosttyTerminalTitleChangedFn", has_target = false)]
    public delegate void TitleChangedFn (Terminal terminal, void* userdata);
    [CCode (cname = "GhosttyTerminalPwdChangedFn", has_target = false)]
    public delegate void PwdChangedFn (Terminal terminal, void* userdata);
    [CCode (cname = "GhosttyTerminalRenderHoldFn", has_target = false)]
    public delegate void RenderHoldFn (Terminal terminal, void* userdata, [CCode (type = "bool")] bool held);
    [CCode (cname = "GhosttyTerminalClipboardWriteFn", has_target = false)]
    public delegate void ClipboardWriteFn (Terminal terminal, void* userdata, [CCode (type = "const GhosttyClipboardWrite*")] ClipboardWrite* write);
    [CCode (cname = "GhosttyTerminalClipboardReadFn", has_target = false)]
    public delegate void ClipboardReadFn (Terminal terminal, void* userdata, [CCode (type = "const GhosttyClipboardRead*")] ClipboardRead* read);

    [Compact]
    [CCode (cname = "struct GhosttyTerminalImpl", free_function = "ghostty_terminal_free", lower_case_cprefix = "ghostty_terminal_")]
    public class Terminal {
        [CCode (cname = "ghostty_terminal_new")]
        public static Result create (void* allocator, out Terminal terminal, uint16 cols, uint16 rows);

        public void reset ();
        public Result resize (uint16 cols, uint16 rows, uint32 cell_width_px, uint32 cell_height_px);
        /* value: a pointer for pointer-typed options (callbacks, userdata),
         * else a pointer to the value; null restores the default. */
        public Result set (TerminalOption option, void* value);
        /* out: a pointer to the output type documented for `data`. */
        public Result get (TerminalData data, void* out);
        public void vt_write ([CCode (array_length_type = "size_t")] uint8[] data);
        public Result scroll_viewport (TerminalScrollViewport behavior);
        public Result grid_ref (Point point, out GridRef out_ref);
    }

    /* ---- Clipboard effects ---- */

    [CCode (cname = "GhosttyClipboardLocation", cprefix = "GHOSTTY_CLIPBOARD_LOCATION_", has_type_id = false)]
    public enum ClipboardLocation {
        STANDARD,
        SELECTION,
        PRIMARY
    }

    [CCode (cname = "GhosttyClipboardContent", has_type_id = false)]
    public struct ClipboardContent {
        public String mime;
        public String data;
    }

    [CCode (cname = "GhosttyClipboardWriteResult", cprefix = "GHOSTTY_CLIPBOARD_WRITE_RESULT_", has_type_id = false)]
    public enum ClipboardWriteResult {
        SUCCESS,
        DENIED,
        UNSUPPORTED,
        BUSY,
        INVALID_DATA,
        IO_ERROR
    }

    /* A sized struct: set size = sizeof (ClipboardWriteReply). */
    [CCode (cname = "GhosttyClipboardWriteReply", has_type_id = false)]
    public struct ClipboardWriteReply {
        public size_t size;
        public ClipboardWriteResult result;
        public bool remember;
    }

    [CCode (cname = "GhosttyClipboardWriteReplyFn", has_target = false)]
    public delegate void ClipboardWriteReplyFn ([CCode (type = "const GhosttyClipboardWrite*")] ClipboardWrite* write, [CCode (type = "const GhosttyClipboardWriteReply*")] ClipboardWriteReply* reply);

    /* Borrowed; valid only during the callback, which must reply before it returns. */
    [CCode (cname = "GhosttyClipboardWrite", has_type_id = false)]
    public struct ClipboardWrite {
        public ClipboardLocation location;
        public ClipboardContent* contents;
        public size_t contents_len;
        public String name;
        public bool granted;
        public bool can_remember;
        public void* ctx;
        public ClipboardWriteReplyFn reply;
    }

    [CCode (cname = "GhosttyClipboardReadResult", cprefix = "GHOSTTY_CLIPBOARD_READ_RESULT_", has_type_id = false)]
    public enum ClipboardReadResult {
        SUCCESS,
        DENIED,
        UNSUPPORTED,
        BUSY,
        IO_ERROR
    }

    /* A sized struct: set size = sizeof (ClipboardReadReply). */
    [CCode (cname = "GhosttyClipboardReadReply", has_type_id = false)]
    public struct ClipboardReadReply {
        public size_t size;
        public ClipboardReadResult result;
        public ClipboardContent* contents;
        public size_t contents_len;
        public String* available;
        public size_t available_len;
        public bool remember;
    }

    [CCode (cname = "GhosttyClipboardReadReplyFn", has_target = false)]
    public delegate void ClipboardReadReplyFn ([CCode (type = "const GhosttyClipboardRead*")] ClipboardRead* read, [CCode (type = "const GhosttyClipboardReadReply*")] ClipboardReadReply* reply);

    /* Borrowed; valid only during the callback, which must reply before it
     * returns. Not replying answers the program with an empty clipboard. */
    [CCode (cname = "GhosttyClipboardRead", has_type_id = false)]
    public struct ClipboardRead {
        public ClipboardLocation location;
        public String* mimes;
        public size_t mimes_len;
        public bool list;
        public String name;
        public bool granted;
        public bool can_remember;
        public void* ctx;
        public ClipboardReadReplyFn reply;
    }

    /* ---- Formatter ---- */

    [CCode (cname = "GhosttyFormatterFormat", cprefix = "GHOSTTY_FORMATTER_FORMAT_", has_type_id = false)]
    public enum FormatterFormat {
        PLAIN,
        VT,
        HTML
    }

    [CCode (cname = "GhosttyFormatterOption", cprefix = "GHOSTTY_FORMATTER_OPT_", has_type_id = false)]
    public enum FormatterOption {
        EMIT,
        UNWRAP,
        TRIM,
        SELECTION,
        EXTRAS
    }

    [Compact]
    [CCode (cname = "struct GhosttyFormatterImpl", free_function = "ghostty_formatter_free", lower_case_cprefix = "ghostty_formatter_")]
    public class Formatter {
        [CCode (cname = "ghostty_formatter_terminal_new")]
        public static Result create (void* allocator, out Formatter formatter, Terminal terminal);

        /* value: a pointer to the option's value type; null restores the default. */
        public Result set (FormatterOption option, void* value);
        /* Free *out_ptr with GhosttyVt.free (null, out_ptr, out_len). Empty
         * output is SUCCESS with a null pointer. */
        public Result format_alloc (void* allocator, out uint8* out_ptr, out size_t out_len);
    }

    /* ---- Render state ---- */

    [Compact]
    [CCode (cname = "struct GhosttyRenderStateImpl", free_function = "ghostty_render_state_free", lower_case_cprefix = "ghostty_render_state_")]
    public class RenderState {
        [CCode (cname = "ghostty_render_state_new")]
        public static Result create (void* allocator, out RenderState state);

        public Result update (Terminal terminal);
    }
}
