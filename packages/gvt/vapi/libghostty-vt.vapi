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
        RENDER_HOLD,
        RESET,
        COLOR_FOREGROUND,
        COLOR_BACKGROUND,
        COLOR_CURSOR,
        COLOR_PALETTE,
        DEFAULT_CURSOR_STYLE,
        SCROLLBACK_MAX_BYTES,
        SCROLLBACK_MAX_LINES,
        MODE,
        SELECTION
    }

    [CCode (cname = "GhosttyColorRgb", has_type_id = false)]
    public struct ColorRgb {
        public uint8 r;
        public uint8 g;
        public uint8 b;
    }

    /* Fills out[256] with the built-in palette. */
    [CCode (cname = "ghostty_color_palette_default")]
    public static void color_palette_default ([CCode (array_length = false)] ColorRgb[] out_palette);

    [CCode (cname = "GhosttyCursorStyle", cprefix = "GHOSTTY_CURSOR_STYLE_", has_type_id = false)]
    public enum CursorStyle {
        BAR,
        BLOCK,
        UNDERLINE,
        BLOCK_HOLLOW
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
        MODE,
        MOUSE_TRACKING,
        ACTIVE_SCREEN,
        SELECTION
    }

    [CCode (cname = "GhosttyTerminalScreen", cprefix = "GHOSTTY_TERMINAL_SCREEN_", has_type_id = false)]
    public enum TerminalScreen {
        PRIMARY,
        ALTERNATE
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
    [CCode (cname = "GhosttyTerminalResetFn", has_target = false)]
    public delegate void ResetFn (Terminal terminal, void* userdata);
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
        /* A snapshot covering all selectable content; NO_VALUE if none. */
        public Result select_all (out Selection out_selection);
        /* out_equal: a C bool*, like the bools Terminal.get writes. */
        public Result selection_equal (Selection a, Selection b, void* out_equal);
    }

    /* ---- Selection gestures (selection.h) ---- */

    [CCode (cname = "GhosttySelectionGestureBehavior", cprefix = "GHOSTTY_SELECTION_GESTURE_BEHAVIOR_", has_type_id = false)]
    public enum SelectionGestureBehavior {
        CELL,
        WORD,
        LINE,
        OUTPUT
    }

    [CCode (cname = "GhosttySelectionGestureBehaviors", has_type_id = false)]
    public struct SelectionGestureBehaviors {
        public SelectionGestureBehavior single_click;
        public SelectionGestureBehavior double_click;
        public SelectionGestureBehavior triple_click;
    }

    [CCode (cname = "GhosttySelectionGestureGeometry", has_type_id = false)]
    public struct SelectionGestureGeometry {
        public uint32 columns;
        public uint32 cell_width;
        public uint32 padding_left;
        public uint32 screen_height;
    }

    [CCode (cname = "GhosttySurfacePosition", has_type_id = false)]
    public struct SurfacePosition {
        public double x;
        public double y;
    }

    [CCode (cname = "GhosttySelectionGestureEventType", cprefix = "GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_", has_type_id = false)]
    public enum SelectionGestureEventType {
        PRESS,
        RELEASE,
        DRAG,
        AUTOSCROLL_TICK,
        DEEP_PRESS
    }

    [CCode (cname = "GhosttySelectionGestureEventOption", cprefix = "GHOSTTY_SELECTION_GESTURE_EVENT_OPT_", has_type_id = false)]
    public enum SelectionGestureEventOption {
        REF,
        POSITION,
        REPEAT_DISTANCE,
        TIME_NS,
        REPEAT_INTERVAL_NS,
        WORD_BOUNDARY_CODEPOINTS,
        BEHAVIORS,
        RECTANGLE,
        GEOMETRY,
        VIEWPORT
    }

    [Compact]
    [CCode (cname = "struct GhosttySelectionGestureEventImpl", free_function = "ghostty_selection_gesture_event_free", lower_case_cprefix = "ghostty_selection_gesture_event_")]
    public class SelectionGestureEvent {
        [CCode (cname = "ghostty_selection_gesture_event_new")]
        public static Result create (void* allocator, out SelectionGestureEvent event, SelectionGestureEventType type);

        /* value: a pointer to the option's value type; null clears it. */
        public Result set (SelectionGestureEventOption option, void* value);
    }

    /* Freeing needs the terminal (ghostty_selection_gesture_free (g, t)), so
     * the handle is held unowned and freed with destroy (). */
    [Compact]
    [CCode (cname = "struct GhosttySelectionGestureImpl", free_function = "", lower_case_cprefix = "ghostty_selection_gesture_")]
    public class SelectionGesture {
        [CCode (cname = "ghostty_selection_gesture_new")]
        public static Result create (void* allocator, out unowned SelectionGesture gesture);

        [CCode (cname = "ghostty_selection_gesture_free")]
        public void destroy (Terminal? terminal);
        public void reset (Terminal terminal);
        /* out_selection: the resulting snapshot, not installed. NO_VALUE
         * when the event produces no selection (a single press, a release). */
        [CCode (cname = "ghostty_selection_gesture_event")]
        public Result apply (Terminal terminal, SelectionGestureEvent event, Selection* out_selection);
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

    /* ---- Render state (render.h) ----
     * Only the struct fields gvt reads are bound; the C header defines the
     * real layout, so sizeof () is right. */

    [CCode (cname = "GhosttyRenderStateDirty", cprefix = "GHOSTTY_RENDER_STATE_DIRTY_", has_type_id = false)]
    public enum RenderStateDirty {
        FALSE,
        PARTIAL,
        FULL
    }

    [CCode (cname = "GhosttyRenderStateData", cprefix = "GHOSTTY_RENDER_STATE_DATA_", has_type_id = false)]
    public enum RenderStateData {
        DIRTY,
        ROW_ITERATOR,
        CURSOR,
        COLORS
    }

    /* A sized struct: set size = sizeof (RenderStateCursor). The viewport
     * fields are undefined unless viewport_has_value. */
    [CCode (cname = "GhosttyRenderStateCursor", has_type_id = false)]
    public struct RenderStateCursor {
        public size_t size;
        public bool viewport_has_value;
        public uint16 viewport_x;
        public uint16 viewport_y;
        public bool wide_tail;
        public bool visible;
        public CursorStyle visual_style;
    }

    /* A sized struct: set size = sizeof (RenderStateColors). */
    [CCode (cname = "GhosttyRenderStateColors", has_type_id = false)]
    public struct RenderStateColors {
        public size_t size;
        public ColorRgb background;
        public ColorRgb foreground;
        public ColorRgb cursor;
        public bool cursor_has_value;
    }

    [CCode (cname = "GhosttyRenderStateRowData", cprefix = "GHOSTTY_RENDER_STATE_ROW_DATA_", has_type_id = false)]
    public enum RenderStateRowData {
        DIRTY,
        CELLS,
        SELECTION,
        VIEWPORT_Y,
        ID
    }

    /* Opaque; two ids are the same row when both words are equal. */
    [CCode (cname = "GhosttyRenderStateRowId", has_type_id = false)]
    public struct RenderStateRowId {
        public uint64 bits[2];
    }

    /* A sized struct: set size = sizeof (RenderStateRowSelection). Ends inclusive. */
    [CCode (cname = "GhosttyRenderStateRowSelection", has_type_id = false)]
    public struct RenderStateRowSelection {
        public size_t size;
        public uint16 start_x;
        public uint16 end_x;
    }

    [CCode (cname = "GhosttyRenderStateRowCellsData", cprefix = "GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_", has_type_id = false)]
    public enum RenderStateRowCellsData {
        RAW,
        STYLE,
        BG_COLOR,
        FG_COLOR,
        GRAPHEMES_UTF8
    }

    /* A caller-owned byte buffer: len is the bytes written, or the size
     * needed on OUT_OF_SPACE. */
    [CCode (cname = "GhosttyBuffer", has_type_id = false)]
    public struct Buffer {
        public uint8* ptr;
        public size_t cap;
        public size_t len;
    }

    [CCode (cname = "GhosttyStyle", has_type_id = false)]
    public struct Style {
        /* GHOSTTY_STYLE_FLAG_* bits; the underline kind in bits 8-10. */
        public uint16 flags;
    }

    [CCode (cname = "GhosttyCellData", cprefix = "GHOSTTY_CELL_DATA_", has_type_id = false)]
    public enum CellData {
        WIDE
    }

    [CCode (cname = "GhosttyCellWide", cprefix = "GHOSTTY_CELL_WIDE_", has_type_id = false)]
    public enum CellWide {
        NARROW,
        WIDE,
        SPACER_TAIL,
        SPACER_HEAD
    }

    /* cell is a GhosttyCell (uint64_t) from RenderStateRowCellsData.RAW. */
    [CCode (cname = "ghostty_cell_get")]
    public static Result cell_get (uint64 cell, CellData data, void* out);

    [Compact]
    [CCode (cname = "struct GhosttyRenderStateImpl", free_function = "ghostty_render_state_free", lower_case_cprefix = "ghostty_render_state_")]
    public class RenderState {
        [CCode (cname = "ghostty_render_state_new")]
        public static Result create (void* allocator, out RenderState state);

        public Result update (Terminal terminal);
        /* out: a pointer to the output type documented for `data`. */
        public Result get (RenderStateData data, void* out);
        /* Clears the global and every per-row dirty flag; updates never do. */
        public Result clean ();
    }

    /* Filled by RenderState.get (ROW_ITERATOR, &iterator); valid until the
     * next update. */
    [Compact]
    [CCode (cname = "struct GhosttyRenderStateRowIteratorImpl", free_function = "ghostty_render_state_row_iterator_free", lower_case_cprefix = "ghostty_render_state_row_iterator_")]
    public class RenderStateRowIterator {
        [CCode (cname = "ghostty_render_state_row_iterator_new")]
        public static Result create (void* allocator, out RenderStateRowIterator iterator);

        public bool next ();
        [CCode (cname = "ghostty_render_state_row_get")]
        public Result get (RenderStateRowData data, void* out);
    }

    /* Filled by RenderStateRowIterator.get (CELLS, &cells); valid until the
     * next update. */
    [Compact]
    [CCode (cname = "struct GhosttyRenderStateRowCellsImpl", free_function = "ghostty_render_state_row_cells_free", lower_case_cprefix = "ghostty_render_state_row_cells_")]
    public class RenderStateRowCells {
        [CCode (cname = "ghostty_render_state_row_cells_new")]
        public static Result create (void* allocator, out RenderStateRowCells cells);

        public bool next ();
        public Result select (uint16 x);
        public Result get (RenderStateRowCellsData data, void* out);
    }

    /* ---- Input: keys (key.h), mouse (mouse.h), paste (paste.h), focus (focus.h) ---- */

    /* Physical keys, layout-independent (W3C KeyboardEvent code). */
    [CCode (cname = "GhosttyKey", cprefix = "GHOSTTY_KEY_", has_type_id = false)]
    public enum Key {
        UNIDENTIFIED,
        BACKQUOTE,
        BACKSLASH,
        BRACKET_LEFT,
        BRACKET_RIGHT,
        COMMA,
        DIGIT_0,
        DIGIT_1,
        DIGIT_2,
        DIGIT_3,
        DIGIT_4,
        DIGIT_5,
        DIGIT_6,
        DIGIT_7,
        DIGIT_8,
        DIGIT_9,
        EQUAL,
        INTL_BACKSLASH,
        INTL_RO,
        INTL_YEN,
        A,
        B,
        C,
        D,
        E,
        F,
        G,
        H,
        I,
        J,
        K,
        L,
        M,
        N,
        O,
        P,
        Q,
        R,
        S,
        T,
        U,
        V,
        W,
        X,
        Y,
        Z,
        MINUS,
        PERIOD,
        QUOTE,
        SEMICOLON,
        SLASH,
        ALT_LEFT,
        ALT_RIGHT,
        BACKSPACE,
        CAPS_LOCK,
        CONTEXT_MENU,
        CONTROL_LEFT,
        CONTROL_RIGHT,
        ENTER,
        META_LEFT,
        META_RIGHT,
        SHIFT_LEFT,
        SHIFT_RIGHT,
        SPACE,
        TAB,
        CONVERT,
        KANA_MODE,
        NON_CONVERT,
        DELETE,
        END,
        HELP,
        HOME,
        INSERT,
        PAGE_DOWN,
        PAGE_UP,
        ARROW_DOWN,
        ARROW_LEFT,
        ARROW_RIGHT,
        ARROW_UP,
        NUM_LOCK,
        NUMPAD_0,
        NUMPAD_1,
        NUMPAD_2,
        NUMPAD_3,
        NUMPAD_4,
        NUMPAD_5,
        NUMPAD_6,
        NUMPAD_7,
        NUMPAD_8,
        NUMPAD_9,
        NUMPAD_ADD,
        NUMPAD_BACKSPACE,
        NUMPAD_CLEAR,
        NUMPAD_CLEAR_ENTRY,
        NUMPAD_COMMA,
        NUMPAD_DECIMAL,
        NUMPAD_DIVIDE,
        NUMPAD_ENTER,
        NUMPAD_EQUAL,
        NUMPAD_MEMORY_ADD,
        NUMPAD_MEMORY_CLEAR,
        NUMPAD_MEMORY_RECALL,
        NUMPAD_MEMORY_STORE,
        NUMPAD_MEMORY_SUBTRACT,
        NUMPAD_MULTIPLY,
        NUMPAD_PAREN_LEFT,
        NUMPAD_PAREN_RIGHT,
        NUMPAD_SUBTRACT,
        NUMPAD_SEPARATOR,
        NUMPAD_UP,
        NUMPAD_DOWN,
        NUMPAD_RIGHT,
        NUMPAD_LEFT,
        NUMPAD_BEGIN,
        NUMPAD_HOME,
        NUMPAD_END,
        NUMPAD_INSERT,
        NUMPAD_DELETE,
        NUMPAD_PAGE_UP,
        NUMPAD_PAGE_DOWN,
        ESCAPE,
        F1,
        F2,
        F3,
        F4,
        F5,
        F6,
        F7,
        F8,
        F9,
        F10,
        F11,
        F12,
        F13,
        F14,
        F15,
        F16,
        F17,
        F18,
        F19,
        F20,
        F21,
        F22,
        F23,
        F24,
        F25,
        FN,
        FN_LOCK,
        PRINT_SCREEN,
        SCROLL_LOCK,
        PAUSE,
        BROWSER_BACK,
        BROWSER_FAVORITES,
        BROWSER_FORWARD,
        BROWSER_HOME,
        BROWSER_REFRESH,
        BROWSER_SEARCH,
        BROWSER_STOP,
        EJECT,
        LAUNCH_APP_1,
        LAUNCH_APP_2,
        LAUNCH_MAIL,
        MEDIA_PLAY_PAUSE,
        MEDIA_SELECT,
        MEDIA_STOP,
        MEDIA_TRACK_NEXT,
        MEDIA_TRACK_PREVIOUS,
        POWER,
        SLEEP,
        AUDIO_VOLUME_DOWN,
        AUDIO_VOLUME_MUTE,
        AUDIO_VOLUME_UP,
        WAKE_UP,
        COPY,
        CUT,
        PASTE
    }

    [CCode (cname = "GhosttyKeyAction", cprefix = "GHOSTTY_KEY_ACTION_", has_type_id = false)]
    public enum KeyAction {
        RELEASE,
        PRESS,
        REPEAT
    }

    /* GhosttyMods is a uint16_t bitmask of the GHOSTTY_MODS_* defines. */
    [Flags]
    [CCode (cname = "GhosttyMods", cprefix = "GHOSTTY_MODS_", has_type_id = false)]
    public enum Mods {
        SHIFT,
        CTRL,
        ALT,
        SUPER,
        CAPS_LOCK,
        NUM_LOCK,
        SHIFT_SIDE,
        CTRL_SIDE,
        ALT_SIDE,
        SUPER_SIDE
    }

    /* GhosttyString again, passed by value (String is passed by pointer). */
    [CCode (cname = "GhosttyString", has_type_id = false)]
    [SimpleType]
    public struct StringValue {
        public uint8* ptr;
        public size_t len;
    }

    /* The text a key event carries is borrowed: it must outlive the event,
     * or be set again. */
    [Compact]
    [CCode (cname = "struct GhosttyKeyEventImpl", free_function = "ghostty_key_event_free", lower_case_cprefix = "ghostty_key_event_")]
    public class KeyEvent {
        [CCode (cname = "ghostty_key_event_new")]
        public static Result create (void* allocator, out KeyEvent event);

        public Result set_action (KeyAction action);
        public Result set_key (Key key);
        public Result set_mods (Mods mods);
        public Result set_consumed_mods (Mods mods);
        public Result set_composing (bool composing);
        public Result set_utf8 (StringValue utf8);
        public Result set_unshifted_codepoint (uint32 codepoint);
    }

    [Compact]
    [CCode (cname = "struct GhosttyKeyEncoderImpl", free_function = "ghostty_key_encoder_free", lower_case_cprefix = "ghostty_key_encoder_")]
    public class KeyEncoder {
        [CCode (cname = "ghostty_key_encoder_new")]
        public static Result create (void* allocator, out KeyEncoder encoder);

        public Result set_from_terminal (Terminal terminal);
        /* OUT_OF_SPACE sets out_written to the size needed. */
        public Result encode (KeyEvent event, [CCode (array_length_type = "size_t")] uint8[]? buf, out size_t out_written);
    }

    [CCode (cname = "GhosttyMouseAction", cprefix = "GHOSTTY_MOUSE_ACTION_", has_type_id = false)]
    public enum MouseAction {
        PRESS,
        RELEASE,
        MOTION
    }

    [CCode (cname = "GhosttyMouseButton", cprefix = "GHOSTTY_MOUSE_BUTTON_", has_type_id = false)]
    public enum MouseButton {
        UNKNOWN,
        LEFT,
        RIGHT,
        MIDDLE,
        FOUR,
        FIVE,
        SIX,
        SEVEN,
        EIGHT,
        NINE,
        TEN,
        ELEVEN
    }

    [CCode (cname = "GhosttyMousePosition", has_type_id = false)]
    [SimpleType]
    public struct MousePosition {
        public float x;
        public float y;
    }

    [CCode (cname = "GhosttyMouseEncoderOption", cprefix = "GHOSTTY_MOUSE_ENCODER_OPT_", has_type_id = false)]
    public enum MouseEncoderOption {
        EVENT,
        FORMAT,
        SIZE,
        ANY_BUTTON_PRESSED,
        TRACK_LAST_CELL
    }

    /* A sized struct: set size = sizeof (MouseEncoderSize). */
    [CCode (cname = "GhosttyMouseEncoderSize", has_type_id = false)]
    public struct MouseEncoderSize {
        public size_t size;
        public uint32 screen_width;
        public uint32 screen_height;
        public uint32 cell_width;
        public uint32 cell_height;
        public uint32 padding_top;
        public uint32 padding_bottom;
        public uint32 padding_right;
        public uint32 padding_left;
    }

    [Compact]
    [CCode (cname = "struct GhosttyMouseEventImpl", free_function = "ghostty_mouse_event_free", lower_case_cprefix = "ghostty_mouse_event_")]
    public class MouseEvent {
        [CCode (cname = "ghostty_mouse_event_new")]
        public static Result create (void* allocator, out MouseEvent event);

        public Result set_action (MouseAction action);
        public Result set_button (MouseButton button);
        public Result clear_button ();
        public Result set_mods (Mods mods);
        public Result set_position (MousePosition position);
    }

    [Compact]
    [CCode (cname = "struct GhosttyMouseEncoderImpl", free_function = "ghostty_mouse_encoder_free", lower_case_cprefix = "ghostty_mouse_encoder_")]
    public class MouseEncoder {
        [CCode (cname = "ghostty_mouse_encoder_new")]
        public static Result create (void* allocator, out MouseEncoder encoder);

        /* value: a pointer to the option's value type; null restores the default. */
        public Result set (MouseEncoderOption option, void* value);
        public Result set_from_terminal (Terminal terminal);
        public Result encode (MouseEvent event, [CCode (array_length_type = "size_t")] uint8[]? buf, out size_t out_written);
    }

    /* Strips unsafe control bytes from data (in place, so pass a copy),
     * brackets it when bracketed, else turns newlines into carriage returns. */
    [CCode (cname = "ghostty_paste_encode")]
    public static Result paste_encode ([CCode (array_length_type = "size_t", type = "char*")] uint8[] data, bool bracketed, [CCode (array_length_type = "size_t")] uint8[]? buf, out size_t out_written);

    [CCode (cname = "GhosttyFocusEvent", cprefix = "GHOSTTY_FOCUS_", has_type_id = false)]
    public enum FocusEvent {
        GAINED,
        LOST
    }

    [CCode (cname = "ghostty_focus_encode")]
    public static Result focus_encode (FocusEvent event, [CCode (array_length_type = "size_t")] uint8[]? buf, out size_t out_written);
}
