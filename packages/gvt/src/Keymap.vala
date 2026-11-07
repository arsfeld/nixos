/*
 * Keymap: hardware keycodes to libghostty's physical keys.
 *
 * Transcribed from src/input/keycodes.zig in the libghostty-vt 1.0.0 source
 * (itself Chromium's dom_code_data.inc): each raw entry whose W3C code that
 * file maps to a key, keyed by its evdev column. Entries it maps to no key
 * (IntlBackslash, NumpadComma, Lang1, the media keys, ...) are left out, so
 * they come out UNIDENTIFIED exactly as in Ghostty; the encoder then works
 * from the key's text. A GDK hardware keycode on Linux is the evdev code + 8.
 */
namespace Gvt {
    internal class Keymap {
        public static GhosttyVt.Key from_gdk (uint keycode) {
            return keycode < 8 ? GhosttyVt.Key.UNIDENTIFIED : from_evdev (keycode - 8);
        }

        public static GhosttyVt.Key from_evdev (uint keycode) {
            switch (keycode) {
            case 0x0001: return GhosttyVt.Key.ESCAPE; // Escape
            case 0x0002: return GhosttyVt.Key.DIGIT_1; // Digit1
            case 0x0003: return GhosttyVt.Key.DIGIT_2; // Digit2
            case 0x0004: return GhosttyVt.Key.DIGIT_3; // Digit3
            case 0x0005: return GhosttyVt.Key.DIGIT_4; // Digit4
            case 0x0006: return GhosttyVt.Key.DIGIT_5; // Digit5
            case 0x0007: return GhosttyVt.Key.DIGIT_6; // Digit6
            case 0x0008: return GhosttyVt.Key.DIGIT_7; // Digit7
            case 0x0009: return GhosttyVt.Key.DIGIT_8; // Digit8
            case 0x000a: return GhosttyVt.Key.DIGIT_9; // Digit9
            case 0x000b: return GhosttyVt.Key.DIGIT_0; // Digit0
            case 0x000c: return GhosttyVt.Key.MINUS; // Minus
            case 0x000d: return GhosttyVt.Key.EQUAL; // Equal
            case 0x000e: return GhosttyVt.Key.BACKSPACE; // Backspace
            case 0x000f: return GhosttyVt.Key.TAB; // Tab
            case 0x0010: return GhosttyVt.Key.Q; // KeyQ
            case 0x0011: return GhosttyVt.Key.W; // KeyW
            case 0x0012: return GhosttyVt.Key.E; // KeyE
            case 0x0013: return GhosttyVt.Key.R; // KeyR
            case 0x0014: return GhosttyVt.Key.T; // KeyT
            case 0x0015: return GhosttyVt.Key.Y; // KeyY
            case 0x0016: return GhosttyVt.Key.U; // KeyU
            case 0x0017: return GhosttyVt.Key.I; // KeyI
            case 0x0018: return GhosttyVt.Key.O; // KeyO
            case 0x0019: return GhosttyVt.Key.P; // KeyP
            case 0x001a: return GhosttyVt.Key.BRACKET_LEFT; // BracketLeft
            case 0x001b: return GhosttyVt.Key.BRACKET_RIGHT; // BracketRight
            case 0x001c: return GhosttyVt.Key.ENTER; // Enter
            case 0x001d: return GhosttyVt.Key.CONTROL_LEFT; // ControlLeft
            case 0x001e: return GhosttyVt.Key.A; // KeyA
            case 0x001f: return GhosttyVt.Key.S; // KeyS
            case 0x0020: return GhosttyVt.Key.D; // KeyD
            case 0x0021: return GhosttyVt.Key.F; // KeyF
            case 0x0022: return GhosttyVt.Key.G; // KeyG
            case 0x0023: return GhosttyVt.Key.H; // KeyH
            case 0x0024: return GhosttyVt.Key.J; // KeyJ
            case 0x0025: return GhosttyVt.Key.K; // KeyK
            case 0x0026: return GhosttyVt.Key.L; // KeyL
            case 0x0027: return GhosttyVt.Key.SEMICOLON; // Semicolon
            case 0x0028: return GhosttyVt.Key.QUOTE; // Quote
            case 0x0029: return GhosttyVt.Key.BACKQUOTE; // Backquote
            case 0x002a: return GhosttyVt.Key.SHIFT_LEFT; // ShiftLeft
            case 0x002b: return GhosttyVt.Key.BACKSLASH; // Backslash
            case 0x002c: return GhosttyVt.Key.Z; // KeyZ
            case 0x002d: return GhosttyVt.Key.X; // KeyX
            case 0x002e: return GhosttyVt.Key.C; // KeyC
            case 0x002f: return GhosttyVt.Key.V; // KeyV
            case 0x0030: return GhosttyVt.Key.B; // KeyB
            case 0x0031: return GhosttyVt.Key.N; // KeyN
            case 0x0032: return GhosttyVt.Key.M; // KeyM
            case 0x0033: return GhosttyVt.Key.COMMA; // Comma
            case 0x0034: return GhosttyVt.Key.PERIOD; // Period
            case 0x0035: return GhosttyVt.Key.SLASH; // Slash
            case 0x0036: return GhosttyVt.Key.SHIFT_RIGHT; // ShiftRight
            case 0x0037: return GhosttyVt.Key.NUMPAD_MULTIPLY; // NumpadMultiply
            case 0x0038: return GhosttyVt.Key.ALT_LEFT; // AltLeft
            case 0x0039: return GhosttyVt.Key.SPACE; // Space
            case 0x003a: return GhosttyVt.Key.CAPS_LOCK; // CapsLock
            case 0x003b: return GhosttyVt.Key.F1; // F1
            case 0x003c: return GhosttyVt.Key.F2; // F2
            case 0x003d: return GhosttyVt.Key.F3; // F3
            case 0x003e: return GhosttyVt.Key.F4; // F4
            case 0x003f: return GhosttyVt.Key.F5; // F5
            case 0x0040: return GhosttyVt.Key.F6; // F6
            case 0x0041: return GhosttyVt.Key.F7; // F7
            case 0x0042: return GhosttyVt.Key.F8; // F8
            case 0x0043: return GhosttyVt.Key.F9; // F9
            case 0x0044: return GhosttyVt.Key.F10; // F10
            case 0x0045: return GhosttyVt.Key.NUM_LOCK; // NumLock
            case 0x0046: return GhosttyVt.Key.SCROLL_LOCK; // ScrollLock
            case 0x0047: return GhosttyVt.Key.NUMPAD_7; // Numpad7
            case 0x0048: return GhosttyVt.Key.NUMPAD_8; // Numpad8
            case 0x0049: return GhosttyVt.Key.NUMPAD_9; // Numpad9
            case 0x004a: return GhosttyVt.Key.NUMPAD_SUBTRACT; // NumpadSubtract
            case 0x004b: return GhosttyVt.Key.NUMPAD_4; // Numpad4
            case 0x004c: return GhosttyVt.Key.NUMPAD_5; // Numpad5
            case 0x004d: return GhosttyVt.Key.NUMPAD_6; // Numpad6
            case 0x004e: return GhosttyVt.Key.NUMPAD_ADD; // NumpadAdd
            case 0x004f: return GhosttyVt.Key.NUMPAD_1; // Numpad1
            case 0x0050: return GhosttyVt.Key.NUMPAD_2; // Numpad2
            case 0x0051: return GhosttyVt.Key.NUMPAD_3; // Numpad3
            case 0x0052: return GhosttyVt.Key.NUMPAD_0; // Numpad0
            case 0x0053: return GhosttyVt.Key.NUMPAD_DECIMAL; // NumpadDecimal
            case 0x0057: return GhosttyVt.Key.F11; // F11
            case 0x0058: return GhosttyVt.Key.F12; // F12
            case 0x0060: return GhosttyVt.Key.NUMPAD_ENTER; // NumpadEnter
            case 0x0061: return GhosttyVt.Key.CONTROL_RIGHT; // ControlRight
            case 0x0062: return GhosttyVt.Key.NUMPAD_DIVIDE; // NumpadDivide
            case 0x0063: return GhosttyVt.Key.PRINT_SCREEN; // PrintScreen
            case 0x0064: return GhosttyVt.Key.ALT_RIGHT; // AltRight
            case 0x0066: return GhosttyVt.Key.HOME; // Home
            case 0x0067: return GhosttyVt.Key.ARROW_UP; // ArrowUp
            case 0x0068: return GhosttyVt.Key.PAGE_UP; // PageUp
            case 0x0069: return GhosttyVt.Key.ARROW_LEFT; // ArrowLeft
            case 0x006a: return GhosttyVt.Key.ARROW_RIGHT; // ArrowRight
            case 0x006b: return GhosttyVt.Key.END; // End
            case 0x006c: return GhosttyVt.Key.ARROW_DOWN; // ArrowDown
            case 0x006d: return GhosttyVt.Key.PAGE_DOWN; // PageDown
            case 0x006e: return GhosttyVt.Key.INSERT; // Insert
            case 0x006f: return GhosttyVt.Key.DELETE; // Delete
            case 0x0075: return GhosttyVt.Key.NUMPAD_EQUAL; // NumpadEqual
            case 0x0077: return GhosttyVt.Key.PAUSE; // Pause
            case 0x007d: return GhosttyVt.Key.META_LEFT; // MetaLeft
            case 0x007e: return GhosttyVt.Key.META_RIGHT; // MetaRight
            case 0x007f: return GhosttyVt.Key.CONTEXT_MENU; // ContextMenu
            case 0x0085: return GhosttyVt.Key.COPY; // Copy
            case 0x0087: return GhosttyVt.Key.PASTE; // Paste
            case 0x0089: return GhosttyVt.Key.CUT; // Cut
            case 0x00b7: return GhosttyVt.Key.F13; // F13
            case 0x00b8: return GhosttyVt.Key.F14; // F14
            case 0x00b9: return GhosttyVt.Key.F15; // F15
            case 0x00ba: return GhosttyVt.Key.F16; // F16
            case 0x00bb: return GhosttyVt.Key.F17; // F17
            case 0x00bc: return GhosttyVt.Key.F18; // F18
            case 0x00bd: return GhosttyVt.Key.F19; // F19
            case 0x00be: return GhosttyVt.Key.F20; // F20
            case 0x00bf: return GhosttyVt.Key.F21; // F21
            case 0x00c0: return GhosttyVt.Key.F22; // F22
            case 0x00c1: return GhosttyVt.Key.F23; // F23
            case 0x00c2: return GhosttyVt.Key.F24; // F24
            default: return GhosttyVt.Key.UNIDENTIFIED;
            }
        }
    }
}
