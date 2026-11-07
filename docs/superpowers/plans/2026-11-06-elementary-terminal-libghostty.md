# elementary Terminal on libghostty-vt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pantheon's terminal (elementary Terminal 8.1.0) runs on Ghostty's terminal engine, libghostty-vt 1.0.0, instead of VTE.

**Architecture:** `packages/libghostty-vt` builds the 1.0.0 C library from its release tarballs. `packages/gvt` is a Vala GTK4 library whose `Gvt.Terminal` widget copies the subset of `Vte.Terminal` elementary uses, backed by libghostty-vt and drawn with GtkSnapshot. `packages/elementary-terminal-ghostty` patches elementary Terminal onto `gvt`, and `modules/desktop/pantheon-terminal.nix` installs it.

**Tech Stack:** Nix, Zig 0.17.0 (build only), C API `ghostty/vt.h`, Vala, GTK 4, Pango, meson, GLib.Test, headless Weston, NixOS VM tests.

**Spec:** `docs/superpowers/specs/2026-11-06-elementary-terminal-libghostty-design.md`

## Global Constraints

- libghostty-vt is exactly **1.0.0**, from `https://release.files.ghostty.org/libghostty-vt/1.0.0/libghostty-vt-1.0.0.tar.gz` plus `libghostty-vt-1.0.0-deps.tar.gz`, built with **Zig 0.17.0** from `pkgs.unstable.zig_0_17` (stable nixpkgs has no 0.17).
- Never `import inputs.nixpkgs*`; take unstable packages from `pkgs.unstable` (CLAUDE.md).
- elementary Terminal source is pinned to tag **8.1.0** on every host.
- `Gvt.*` public names, signatures, property names and signal names copy VTE 0.84's (`vte-2.91-gtk4.vapi`) exactly. Copy only what elementary uses; add a member only when the port needs it.
- Only `Engine.vala` calls libghostty C functions.
- The `vadjustment` counts rows. `scroll_unit_is_pixels` is stored and ignored.
- PTY reads are at most **64 KiB** per main-loop dispatch; at most one redraw per frame clock tick.
- OSC 52 writes are always honoured; OSC 52 reads only when GSettings key `clipboard-read` (schema `io.github.arsfeld.gvt`) is `true`, default `false`.
- Every unit test runs in the package's `doCheck` under `weston --backend=headless`.
- Commits go straight to master, conventional format, scope `modules` (CLAUDE.md, user memory). Never mention Claude.
- Any new file must be `git add`ed (or `git add -N`) before `nix build` can see it.
- Run `just fmt` before each commit that touches `.nix`.
- Never build or evaluate cylon-link; build one host at a time, niced.

## Review Focus

1. **Wide and combined characters** (CJK, emoji with ZWJ, combining accents): a wide glyph spans exactly two cells and the next character starts at column +2. Test in Task 4.
2. **Huge output bursts** (`seq 1 5000000`, `cat` of a large log): the window keeps handling input and redraws during the burst. Test in Task 3 (read cap) and Task 4 (one redraw per tick).
3. **A child that prints and exits immediately** (`printf X; exit 3`): every byte reaches the screen before `child_exited` fires. Test in Task 3.
4. **Tiny or zero allocations** (tab being created, window minimised): the terminal never resizes to 0 rows or columns; it clamps to 1×1. Test in Task 4.
5. **Dead keys and input methods** (`´` + `e`, compose, IBus): composed text reaches the shell as UTF-8 and pre-edit does not leak bytes. Test in Task 5.

---

### Task 1: libghostty-vt 1.0.0 package

> Note: the package was later renamed to `packages/libghostty-vt-1` (attribute `libghostty-vt-1`) so it no longer shadows nixpkgs' `libghostty-vt`; devenv in raider's closure links that one and fails against the 1.0.0 ABI.

**Files:**
- Create: `packages/libghostty-vt/package.nix`
- Create: `packages/libghostty-vt/smoke.c`

**Interfaces:**
- Produces: `pkgs.libghostty-vt` (overlay-provided, shadows nixpkgs-unstable's 0.1.0) with outputs `out` (`lib/libghostty-vt.so*`) and `dev` (`include/ghostty/vt.h`, `include/ghostty/vt/*.h`, `lib/pkgconfig/libghostty-vt.pc`), `version = "1.0.0"`, and `passthru.tests.smoke`.

- [ ] **Step 1: Write the smoke test `smoke.c`**

Includes `<ghostty/vt.h>`; asserts `GHOSTTY_VT_VERSION_MAJOR == 1`; creates an 80×24 terminal with `ghostty_terminal_new(NULL, &t, 80, 24)`, writes `"hello\x1b]2;smoke\x07"` with `ghostty_terminal_vt_write`, reads `GHOSTTY_TERMINAL_DATA_CURSOR_X` with `ghostty_terminal_get` and exits non-zero unless it is `5`, then reads `GHOSTTY_TERMINAL_DATA_TITLE` and exits non-zero unless it is `smoke`. Model the calls on `example/c-vt-hello/src/main.c` in the tarball.

- [ ] **Step 2: Write `package.nix`**

`stdenv.mkDerivation` with two `fetchurl` sources (main and deps tarballs, unpacked side by side via `srcs` + `sourceRoot = "libghostty-vt-1.0.0"`), `nativeBuildInputs = [unstable.zig_0_17 pkg-config]`, `dontSetZigDefaultFlags = true`, `zigBuildFlags = ["--system" "../libghostty-vt-1.0.0-deps" "-Doptimize=ReleaseFast" "-Dcpu=baseline"]`, `ZIG_GLOBAL_CACHE_DIR` set to a fresh `$TMPDIR` subdirectory in `preBuild`, `outputs = ["out" "dev"]` with the static archive moved to `dev`. `passthru.tests.smoke` is a `runCommandCC` that compiles `smoke.c` with `pkg-config --cflags --libs libghostty-vt` and runs it. Fill the two hashes from the first failing build.

- [ ] **Step 3: Build and run the smoke test**

Run: `git add -N packages/libghostty-vt && nice nix build .#libghostty-vt .#libghostty-vt.tests.smoke -L`
Expected: both build; `result-dev/lib/pkgconfig/libghostty-vt.pc` contains `Version: 1.0.0`.

- [ ] **Step 4: Commit**

```bash
just fmt
git add packages/libghostty-vt
git commit -m "feat(modules): package libghostty-vt 1.0.0"
```

---

### Task 2: gvt skeleton and `Engine`

**Files:**
- Create: `packages/gvt/package.nix`, `packages/gvt/meson.build`, `packages/gvt/meson_options.txt`
- Create: `packages/gvt/vapi/ghostty-vt.vapi` (handwritten, `[CCode (cheader_filename = "ghostty/vt.h")]`, only the symbols Engine uses)
- Create: `packages/gvt/src/Engine.vala`
- Create: `packages/gvt/data/io.github.arsfeld.gvt.gschema.xml`
- Test: `packages/gvt/tests/engine-test.vala`, `packages/gvt/tests/meson.build`

**Interfaces:**
- Consumes: `pkgs.libghostty-vt` (Task 1).
- Produces (all `internal`, namespace `Gvt`):
  - `class Engine : Object` — `Engine (uint16 cols, uint16 rows)`; `void write (uint8[] bytes)`; `void resize (uint16 cols, uint16 rows, uint32 cell_w, uint32 cell_h)`; `uint16 cols {get;}`, `uint16 rows {get;}`; `long scrollback_rows {get;}` (`GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS`); `void cursor (out long col, out long abs_row)` where `abs_row = scrollback_rows + CURSOR_Y`; `string? title {get;}`; `string? pwd {get;}`; `string text_range (long start_row, long start_col, long end_row, long end_col)` via the formatter, plain-text; `void reset (bool clear_history)`; `void scroll_viewport (long delta_rows)`; `long viewport_top {get;}`; `bool mode (uint16 mode)`; `unowned GhosttyRenderState render_state ()` after `ghostty_render_state_update`.
  - Signals: `write_pty (uint8[] bytes)` (from `GHOSTTY_TERMINAL_OPT_WRITE_PTY`), `title_changed ()`, `pwd_changed ()`, `bell ()`, `clipboard_write (string text)`, `clipboard_read_requested (ClipboardReply reply)` with `delegate void ClipboardReply (string? text)`, `render_hold (bool held)`.
  - The libghostty callbacks get `this` through `GHOSTTY_TERMINAL_OPT_USERDATA`.
  - Allocation failure from any libghostty call raises `critical` and emits `failed ()`.
  - GSettings schema `io.github.arsfeld.gvt` with key `clipboard-read` (`b`, default `false`).
- `package.nix`: `stdenv.mkDerivation` with meson, ninja, vala, pkg-config, `wrapGAppsNoGuiHook`; buildInputs gtk4, pango, libghostty-vt, glib; `nativeCheckInputs = [weston]`; `doCheck = true`; `preCheck` starts `weston --backend=headless --socket=gvt-test --idle-time=0 &` with `XDG_RUNTIME_DIR=$TMPDIR` and exports `WAYLAND_DISPLAY=gvt-test`, `GSETTINGS_SCHEMA_DIR` pointing at the compiled schema in the build tree. Installs `gvt-1.vapi`, `gvt-1.deps`, `gvt-1.pc`, `libgvt-1.so`.

- [ ] **Step 1: Write the failing tests in `engine-test.vala`**

```vala
// /engine/text: write "hello" → text_range(0,0,0,5) == "hello"; cursor() == (5, 0)
// /engine/title: write "\x1b]2;hi\x07" → title_changed fired once, title == "hi"
// /engine/pwd: write "\x1b]7;file://host/tmp\x07" → pwd_changed fired, pwd == "file://host/tmp"
// /engine/bell: write "\x07" → bell fired once
// /engine/osc52-write: write "\x1b]52;c;aGVsbG8=\x07" → clipboard_write("hello")
// /engine/osc52-read: write "\x1b]52;c;?\x07" → clipboard_read_requested fired; reply("x") → write_pty emits bytes containing "eA=="
// /engine/da1: write "\x1b[c" → write_pty emits bytes starting with "\x1b[?"
// /engine/scrollback: 5-row engine, write 10 lines "L0\r\n".."L9\r\n" → scrollback_rows >= 5; cursor abs_row == scrollback_rows + cursor_y
// /engine/resize: resize(40, 10, 8, 16) → cols == 40, rows == 10
```

- [ ] **Step 2: Run to verify failure**

Run: `git add -N packages/gvt && nice nix build .#gvt -L`
Expected: FAIL compiling the test (`Gvt.Engine` not defined).

- [ ] **Step 3: Implement the vapi, `Engine.vala`, meson, schema and `package.nix`**

- [ ] **Step 4: Run to verify the tests pass**

Run: `nice nix build .#gvt -L`
Expected: PASS; log shows `engine-test` with 9 `ok` lines.

- [ ] **Step 5: Commit**

```bash
just fmt
git add packages/gvt
git commit -m "feat(modules): gvt engine over libghostty-vt"
```

---

### Task 3: `Pty`

**Files:**
- Create: `packages/gvt/src/Pty.vala`
- Create: `packages/gvt/vapi/posix-extra.vapi` (`openpty` from `<pty.h>`, `TIOCSCTTY`, `TIOCSWINSZ`, `struct winsize`)
- Test: `packages/gvt/tests/pty-test.vala`

**Interfaces:**
- Produces (namespace `Gvt`):
  - `public class Pty : Object` — `public int fd { get; construct; }` (VTE name, used by elementary for `tcgetpgrp`).
  - `internal` on `Pty`: `static Pty spawn (string? cwd, string[] argv, string[]? envv, SpawnFlags flags, owned SpawnChildSetupFunc? setup, out Pid pid) throws Error` (openpty, fork, `setsid`, `TIOCSCTTY`, dup2 to 0/1/2, chdir, `execvpe` when `SEARCH_PATH` else `execve`; `TERM=xterm-ghostty` is **not** set, the env is `envv` plus `TERM=xterm-256color` and `COLORTERM=truecolor` unless `envv` sets them); `void write (uint8[] bytes)` (queues and drains with a `POLLOUT` source, never blocks); `void set_size (uint16 cols, uint16 rows, uint16 px_w, uint16 px_h)` (`TIOCSWINSZ`); signals `data (uint8[] chunk)` and `exited (int status)`.
  - Reads: a `GLib.IOChannel`/`Unix.fd_add` source, one `read()` of at most 65536 bytes per dispatch. `exited` fires only after EOF/EIO has been seen on the fd **and** the `ChildWatch` reported the status, so all output is delivered first.

- [ ] **Step 1: Write the failing tests**

```vala
// /pty/output-then-exit: spawn sh -c 'printf X; exit 3' → concatenated data == "X", then exited(3); assert data arrived before exited
// /pty/resize: set_size(42, 7, 0, 0) then spawn sh -c 'stty size' → data contains "7 42"
// /pty/write: spawn cat → write("abc\n") → data contains "abc"
// /pty/read-cap: spawn sh -c 'head -c 1000000 /dev/zero' → every data chunk length <= 65536, total == 1000000
// /pty/exec-fail: spawn {"/nonexistent"} → throws (SpawnError), no exited signal
```

- [ ] **Step 2: Run to verify failure** — `nice nix build .#gvt -L`; expected FAIL (`Gvt.Pty.spawn` not defined).
- [ ] **Step 3: Implement `Pty.vala`** (Posix + Linux vapis plus `vapi/posix-extra.vapi`; link `-lutil` if `openpty` needs it).
- [ ] **Step 4: Run to verify pass** — `nice nix build .#gvt -L`; expected 5 new `ok` lines.
- [ ] **Step 5: Commit** — `git commit -m "feat(modules): gvt pty"`

---

### Task 4: `Gvt.Terminal` widget and `Renderer`

**Files:**
- Create: `packages/gvt/src/Terminal.vala`, `packages/gvt/src/Renderer.vala`, `packages/gvt/src/Enums.vala`
- Test: `packages/gvt/tests/terminal-test.vala`, `packages/gvt/tests/renderer-test.vala`

**Interfaces:**
- Consumes: `Engine` (Task 2), `Pty` (Task 3).
- Produces (public, namespace `Gvt`, signatures copied from VTE 0.84):
  - `enum CursorShape { BLOCK, IBEAM, UNDERLINE }`, `enum Format { TEXT = 1, HTML = 2 }`, `[Flags] enum PtyFlags { NO_LASTLOG, NO_UTMP, NO_WTMP, NO_HELPER, NO_FALLBACK, NO_SESSION, NO_CTTY, DEFAULT = 0 }`, `string get_user_shell ()` (passwd entry, fallback `/bin/sh`).
  - `delegate void TerminalSpawnAsyncCallback (Terminal terminal, Pid pid, Error? error)`.
  - `class Terminal : Gtk.Widget, Gtk.Scrollable` with:
    - `void spawn_async (PtyFlags pty_flags, string? working_directory, string[] argv, string[]? envv, SpawnFlags spawn_flags, owned SpawnChildSetupFunc? child_setup, int timeout, Cancellable? cancellable, TerminalSpawnAsyncCallback? callback)` — callback invoked from idle, error on exec failure.
    - `void feed_child (uint8[]? text)`, `unowned Pty? get_pty ()`, `void get_cursor_position (out long column, out long row)`, `string? get_text_range_format (Format format, long start_row, long start_col, long end_row, long end_col, out size_t length)` (`HTML` returns `null`), `long get_char_width ()`, `long get_char_height ()`, `void set_font (Pango.FontDescription? font_desc)`, `void set_colors (Gdk.RGBA? foreground, Gdk.RGBA? background, Gdk.RGBA[]? palette)`, `void set_color_cursor (Gdk.RGBA? cursor_background)`, `void set_cursor_shape (CursorShape shape)`, `void reset (bool clear_tabstops, bool clear_history)`.
    - Properties: `double font_scale` (clamped 0.25–4.0, notifies), `uint scrollback_lines` (→ `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES`), `bool audible_bell`, `bool pointer_autohide`, `bool enable_fallback_scrolling`, `bool scroll_unit_is_pixels`, `string window_title { get; }`, plus `Gtk.Scrollable`'s four.
    - Signals: `virtual signal void bell ()`, `child_exited (int status)`, `contents_changed ()`, `window_title_changed ()`, and `[Signal (action = true)] virtual signal void increase_font_size ()` / `decrease_font_size ()` (default handlers ×/÷ 1.2).
  - `internal class Renderer` — `Renderer (Terminal owner)`; `void snapshot (Gtk.Snapshot s, int width, int height)`; caches one `Gsk.RenderNode` per row keyed by `GHOSTTY_RENDER_STATE_ROW_DATA_ID`, rebuilt only when the row is dirty or font/colors changed; draws backgrounds as merged color rects, text as one `Pango.Layout` per run of identical style, cursor per `CursorShape`, selected cells with the theme selection color; `void cell_size (out int w, out int h)` from Pango metrics of the scaled font.
  - `Terminal` maps allocation → `cols = max(1, width / cell_w)`, `rows = max(1, height / cell_h)`, calls `Engine.resize` and `Pty.set_size`; output from `Pty.data` goes to `Engine.write`, then `queue_draw` is requested through a single pending `add_tick_callback`, and is suppressed while `render_hold(true)`. `contents_changed` fires once per tick that processed output.
  - `Engine.failed` (spec: allocation failure closes only that tab): send `SIGHUP` to the child and emit `child_exited (-1)`; elementary already closes the tab on `child_exited`.
  - `vadjustment`: `upper = scrollback_rows + rows`, `page_size = rows`, `value = viewport_top`; changing `value` calls `Engine.scroll_viewport`.

- [ ] **Step 1: Write the failing tests**

```vala
// terminal-test (Gtk.init, a Gtk.Window holding the Terminal, presented):
// /terminal/spawn: spawn_async {"sh","-c","printf 'hi\\n'; exit 3"} → callback pid > 0; child_exited(3);
//    get_text_range_format(TEXT,0,0,0,2,out len) == "hi"
// /terminal/exec-error: spawn_async {"/nonexistent"} → callback error != null
// /terminal/title: feed via child printf '\033]2;T\007' → window_title_changed fired, window_title == "T"
// /terminal/cursor: after "hi\n", get_cursor_position → (0, 1)
// /terminal/zero-size: allocate 0×0 → engine cols == 1 and rows == 1 (no critical)
// /terminal/font-scale: increase_font_size.emit() → font_scale == 1.2; get_char_width() grew
// /terminal/vadjustment: 5-row terminal after 20 lines → vadjustment.upper >= 20, page_size == 5
// /terminal/engine-failed: Engine.failed.emit() → child_exited(-1) fired, no crash
// /terminal/one-draw-per-tick: child writes 200 separate chunks within one frame → snapshot called <= 2 times before idle
// renderer-test (render the widget to a texture via Gtk.WidgetPaintable + Gsk.Renderer.render_texture):
// /renderer/colors: set_colors(fg=#ffffff, bg=#000000, 16-entry palette with red #ff0000 at 1);
//    output "\033[41m  \033[0m" → pixel at centre of cell (0,0) is #ff0000, cell (5,0) is #000000
// /renderer/wide: output "中a" → 'a' is drawn starting at column 2 (pixel in column 2's cell is not background)
// /renderer/size: 80×24 with char w×h → texture is at least 80w × 24h
```

- [ ] **Step 2: Run to verify failure** — `nice nix build .#gvt -L`; expected FAIL (`Gvt.Terminal` not defined).
- [ ] **Step 3: Implement `Enums.vala`, `Renderer.vala`, `Terminal.vala`**
- [ ] **Step 4: Run to verify pass** — `nice nix build .#gvt -L`; expected 12 new `ok` lines.
- [ ] **Step 5: Commit** — `git commit -m "feat(modules): gvt terminal widget and renderer"`

---

### Task 5: `Input` — keys, IME, mouse, paste, focus

**Files:**
- Create: `packages/gvt/src/Input.vala`, `packages/gvt/src/Keymap.vala`
- Modify: `packages/gvt/src/Terminal.vala` (controllers and `paste_text`)
- Test: `packages/gvt/tests/input-test.vala`

**Interfaces:**
- Consumes: `Engine` encoders via new Engine methods `uint8[] encode_key (GhosttyKey key, GhosttyKeyAction action, GhosttyMods mods, string? utf8, unichar unshifted)`, `uint8[] encode_mouse (...)`, `uint8[] encode_paste (string text)` (`ghostty_paste_encode`, honours bracketed paste), `uint8[] encode_focus (bool focused)`; each sets encoder state with `*_set_from_terminal` first.
- Produces:
  - `Keymap.from_evdev (uint keycode) → GhosttyKey`: a static table transcribed from `src/input/keycodes.zig` in the 1.0.0 tarball (GDK hardware keycode − 8 = evdev code).
  - `internal class Input` owning a `Gtk.EventControllerKey` with a `Gtk.IMMulticontext`: `key_pressed`/`key_released` → `encode_key` → `Pty.write`; IM `commit` → write UTF-8 text; while pre-edit is non-empty, key events go only to the IM.
  - Mouse: when `GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING` is not off, click/motion/scroll events are encoded and written and do **not** reach Selection; otherwise they go to Selection (Task 6) and scroll moves `vadjustment`.
  - `public void paste_text (string text)` (VTE signature) → `encode_paste` → write.
  - Focus in/out writes `encode_focus` when mode 1004 is set.

- [ ] **Step 1: Write the failing tests**

```vala
// Drive Input directly with synthetic values (no real key events); capture Pty.write bytes via a test pty spawning `cat -v`, or via Engine.write_pty stub.
// /input/plain: key A, utf8 "a" → "a"
// /input/ctrl-c: key C + CTRL → "\x03"
// /input/app-cursor: after engine.write("\x1b[?1h"), key UP → "\x1bOA"; without it → "\x1b[A"
// /input/kitty: after engine.write("\x1b[>1u"), key ESCAPE → "\x1b[27u"
// /input/ime-commit: IM commit "é" → "é" (UTF-8 0xC3 0xA9); pre-edit "´" active → key E produces no bytes
// /input/paste-bracketed: after "\x1b[?2004h", paste_text("a\x1b[201~b") → starts with "\x1b[200~", ends with "\x1b[201~", and the payload contains no premature "\x1b[201~"
// /input/paste-plain: paste_text("ls\n") without 2004 → bytes equal ghostty_paste_encode output ("ls\r")
// /input/mouse-sgr: after "\x1b[?1000h\x1b[?1006h", left press at cell (2,3) → "\x1b[<0;3;4M"
// /input/focus: after "\x1b[?1004h", focus out → "\x1b[O"
// /input/keymap: Keymap.from_evdev(30) == KEY_A; from_evdev(1) == ESCAPE
```

- [ ] **Step 2: Run to verify failure** — `nice nix build .#gvt -L`; expected FAIL.
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run to verify pass** — expected 10 new `ok` lines.
- [ ] **Step 5: Commit** — `git commit -m "feat(modules): gvt keyboard, IME, mouse and paste input"`

---

### Task 6: `Selection` and `Clipboard`

**Files:**
- Create: `packages/gvt/src/Selection.vala`, `packages/gvt/src/Clipboard.vala`
- Modify: `packages/gvt/src/Terminal.vala`
- Test: `packages/gvt/tests/selection-test.vala`

**Interfaces:**
- Consumes: Engine methods added here: `void select_all ()`, `void clear_selection ()`, `bool has_selection {get;}`, `string? selection_text ()` (formatter over the selection), `void gesture (SelectionGestureEvent ev)` wrapping `ghostty_selection_gesture_*` (press/drag/release with click count 1/2/3 = char/word/line).
- Produces (public, VTE names):
  - `void select_all ()`, `void unselect_all ()`, `bool get_has_selection ()`, `virtual signal void selection_changed ()`, `[Signal (action = true)] virtual signal void copy_clipboard ()` (default: selection text → display clipboard), `copy_primary ()` method (selection text → primary clipboard), `[Signal (action = true)] virtual signal void paste_clipboard ()` (default: read display clipboard → `paste_text`). Primary is also set whenever a mouse selection ends.
  - `Clipboard`: `Engine.clipboard_write` → `Gdk.Display.get_clipboard().set_text`; `Engine.clipboard_read_requested` → reply with clipboard text only when `io.github.arsfeld.gvt` `clipboard-read` is true, else reply `null` (libghostty answers empty).

- [ ] **Step 1: Write the failing tests**

```vala
// /selection/all: output "one\r\ntwo" → select_all(); get_has_selection(); copy_clipboard.emit() → display clipboard text == "one\ntwo"
// /selection/wrapped: 10-col terminal, output 15 'x' (soft-wraps), gesture press at (0,0), drag to (4,1) → selection_text() == "xxxxxxxxxxxxxxx" (15 x's, no newline)
// /selection/word: double-click gesture on "foo bar" at col 5 → selection_text() == "bar"
// /selection/changed: select_all then unselect_all → selection_changed fired twice
// /clipboard/osc52-write: child prints OSC 52 "aGVsbG8=" → display clipboard == "hello"
// /clipboard/osc52-read-off: clipboard "secret", default settings, child sends OSC 52 "?" → pty receives no "c2VjcmV0"
// /clipboard/osc52-read-on: same with clipboard-read=true (GSettings memory backend) → pty receives "c2VjcmV0"
// /clipboard/paste: clipboard "ls" → paste_clipboard.emit() → child (cat) echoes "ls"
```

- [ ] **Step 2: Run to verify failure** — expected FAIL.
- [ ] **Step 3: Implement** (tests use `GSETTINGS_BACKEND=memory`).
- [ ] **Step 4: Run to verify pass** — expected 8 new `ok` lines.
- [ ] **Step 5: Commit** — `git commit -m "feat(modules): gvt selection and OSC 52 clipboard"`

---

### Task 7: `Search` and URL matching

**Files:**
- Create: `packages/gvt/src/Search.vala`, `packages/gvt/src/Regex.vala`
- Modify: `packages/gvt/src/Terminal.vala`
- Test: `packages/gvt/tests/search-test.vala`

**Interfaces:**
- Consumes: Engine methods added here wrapping `ghostty_search_new/set(NEEDLE)/feed/tick/select_next/select_prev/get(SELECTED_MATCH, VIEWPORT_MATCHES)`; `string row_text (long abs_row)`.
- Produces (public, VTE names):
  - `class Regex` — `Regex.for_search (string pattern, ssize_t pattern_length, uint32 flags) throws Error` stores the literal pattern (flags ignored: the find bar is always literal and case-insensitive); `Regex.for_match (string pattern, ssize_t pattern_length, uint32 flags) throws Error` compiles a `GLib.Regex` (`MULTILINE`) and throws its error on a bad pattern.
  - `void search_set_regex (Regex? regex, uint32 flags)`, `void search_set_wrap_around (bool wrap_around)`, `bool search_find_next ()`, `bool search_find_previous ()` — select the match (so it highlights and scrolls into view via `GHOSTTY_SEARCH_SCROLL_IF_NEEDED`); return `false` at the end when wrap-around is off. Search state is fed from a low-priority idle so a big scrollback never blocks a frame.
  - `int match_add_regex (Regex regex, uint32 flags)`, `void match_set_cursor_name (int tag, string cursor_name)`, `void match_remove_all ()`, `string? check_match_at (double x, double y, out int tag)` — runs the registered regexes over the row under (x, y) and returns the match covering that column; motion over a match sets the widget cursor to that tag's name.

- [ ] **Step 1: Write the failing tests**

```vala
// /search/next: output "alpha\r\nbeta\r\nALPHA" → search_set_regex(for_search("alpha")) → search_find_next() true, again true (case-insensitive 2nd hit), again false (wrap off)
// /search/wrap: search_set_wrap_around(true) → third search_find_next() true
// /search/previous: from the start, search_find_previous() with wrap on → selects the last hit
// /search/scrollback: 5-row terminal, "needle" on line 0 then 20 lines → search_find_next() true and vadjustment.value moved to show line 0
// /match/url: match_add_regex(for_match("https?://[^ ]+")) → output "see https://x.org now"; check_match_at at col 8 → "https://x.org"; at col 1 → null
// /match/bad-regex: for_match("(") throws
```

- [ ] **Step 2: Run to verify failure** — expected FAIL.
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run to verify pass** — expected 6 new `ok` lines.
- [ ] **Step 5: Commit** — `git commit -m "feat(modules): gvt search and URL matching"`

---

### Task 8: elementary Terminal on gvt

**Files:**
- Create: `packages/elementary-terminal-ghostty/package.nix`
- Create: `packages/elementary-terminal-ghostty/gvt.patch`
- Modify (only if the port needs a missing member): `packages/gvt/src/*.vala` and its tests

**Interfaces:**
- Consumes: `pkgs.gvt` (`gvt-1` pkg-config/vapi), all public `Gvt.*` from Tasks 4–7.
- Produces: `pkgs.elementary-terminal-ghostty`, binary `io.elementary.terminal`, same desktop file and GSettings schema as upstream.

- [ ] **Step 1: Write `package.nix`**

`pantheon.elementary-terminal.overrideAttrs` with `version = "8.1.0"`, `src = fetchFromGitHub { owner = "elementary"; repo = "terminal"; rev = "8.1.0"; hash = …; }`, `patches = (old.patches or []) ++ [./gvt.patch]`, and `buildInputs` with `vte-gtk4` filtered out and `gvt` added.

- [ ] **Step 2: Produce the patch**

In a scratch checkout of tag 8.1.0: `meson.build` `vte_dep = dependency('gvt-1')`; `sed -i 's/\bVte\./Gvt./g'` over `src/`; remove `GLib.Regex.escape_string (…)` around `search_term` in `src/Widgets/SearchToolbar.vala`; build, and fix each remaining compile error either in the patch (elementary-side) or by adding the exact VTE member to gvt with a test (gvt-side, per the Global Constraints rule). `git diff > gvt.patch`. Head the patch with a comment listing every file and hunk it touches.

- [ ] **Step 3: Build**

Run: `nice nix build .#elementary-terminal-ghostty -L`
Expected: builds; `nix-store -q --references $(readlink -f result) | grep -c vte` prints `0`; elementary's own `UnsafePasteTest` passes.

- [ ] **Step 4: Commit**

```bash
just fmt
git add packages/elementary-terminal-ghostty packages/gvt
git commit -m "feat(modules): elementary Terminal 8.1.0 on gvt"
```

---

### Task 9: End-to-end VM test

**Files:**
- Create: `tests/pantheon-terminal-test.nix`
- Modify: `modules/flake/checks.nix` (add `pantheon-terminal-test` in the x86_64-only block, beside `pantheon-tailscale-test`, passing `{inherit self;}`)

**Interfaces:**
- Consumes: `pkgs.elementary-terminal-ghostty` (Task 8), `self.lib.overlays`.

- [ ] **Step 1: Write the test**

Node: Pantheon session as in `tests/pantheon-tailscale-test.nix` (auto-login user `arosenfeld`, `virtualisation.memorySize = 2047`), `nixpkgs.overlays = self.lib.overlays`, `environment.systemPackages = [pkgs.elementary-terminal-ghostty pkgs.wl-clipboard]`, and a script `/etc/gvt-e2e.sh` that prints `\033]52;c;$(printf e2e-ok | base64)\007`, `\033]2;gvt-e2e\007` and `\033[31mRED\033[0m`, then sleeps. Test script: wait for the session, run `io.elementary.terminal -e /etc/gvt-e2e.sh` as the user, then:

```python
machine.wait_until_succeeds("su - arosenfeld -c 'WAYLAND_DISPLAY=wayland-0 wl-paste -n' | grep -x e2e-ok")
machine.wait_for_window("gvt-e2e")
machine.screenshot("pantheon-terminal")
```

- [ ] **Step 2: Run it**

Run: `git add -N tests/pantheon-terminal-test.nix && nice nix build .#checks.x86_64-linux.pantheon-terminal-test -L`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
just fmt
git add tests/pantheon-terminal-test.nix modules/flake/checks.nix
git commit -m "test(modules): end-to-end OSC 52 and title check for the gvt terminal"
```

---

### Task 10: Switch Pantheon to the gvt terminal

**Files:**
- Modify: `modules/desktop/pantheon-terminal.nix`
- Delete: `modules/desktop/_vte-osc52-clipboard.patch`
- Modify: `CLAUDE.md` (the `desktop` row in the Features table: "`pantheon-terminal` (elementary Terminal on libghostty-vt via `packages/gvt`)")
- Modify: `docs/superpowers/specs/2026-11-06-elementary-terminal-libghostty-design.md` (Status line → implemented, with the commit)

**Interfaces:**
- Consumes: `pkgs.elementary-terminal-ghostty`.

- [ ] **Step 1: Try it on raider without committing the switch**

Rewrite `pantheon-terminal.nix` to install `pkgs.elementary-terminal-ghostty` (keeping the `excludePackages` swap), with a header comment describing gvt, libghostty-vt 1.0.0 and where the patch lives. Run `just test raider`.

- [ ] **Step 2: Work the parity checklist with the user**

Every item in the spec's "Manual parity checklist" is checked by the user on raider and recorded in the commit body. Any failure becomes a gvt fix with a test (back to the owning task's file) before continuing. This step needs the user; do not tick it alone.

- [ ] **Step 3: Remove the VTE patch, build both desktop hosts**

`git rm modules/desktop/_vte-osc52-clipboard.patch`. Then, one at a time:
Run: `nice just build raider` then `nice just build blackbird`
Expected: both succeed.

- [ ] **Step 4: Commit and push**

```bash
just fmt
git add -A modules/desktop CLAUDE.md docs/superpowers/specs/2026-11-06-elementary-terminal-libghostty-design.md
git commit -m "feat(modules): Pantheon terminal runs on libghostty-vt"
git push -u origin master
```

- [ ] **Step 5: Deploy raider**

Run: `just deploy raider` (blackbird gets it on its next deploy).
Expected: activation succeeds; `io.elementary.terminal` opens a working shell.
