# elementary Terminal on libghostty-vt

Date: 2026-11-06
Status: approved design, not yet implemented

## Goal

Replace VTE inside Pantheon's terminal (elementary Terminal) with the Ghostty
terminal engine, through libghostty-vt (https://lib.ghostty.org/). The app keeps
elementary's look and integration; the engine underneath becomes Ghostty's.

What it must do better than the current VTE build, all four counted:

- **Protocol correctness**: Ghostty-grade VT behaviour, including the kitty
  keyboard protocol, synchronized output (mode 2026), grapheme handling, and
  full OSC 52, so zellij, nvim and Claude Code behave as they do in Ghostty.
- **Performance**: throughput and input latency at least on par with VTE.
- **Same engine as Ghostty**: one engine across the desktop.
- **Learning**: this is also an exploration of libghostty, so a rough edge
  found during the work is a finding, not a failure.

## What libghostty-vt is, and is not

libghostty-vt 1.0.0 is a C library (header `ghostty/vt.h`, MIT) that parses the
bytes a program writes and exposes terminal state: screen, cursor, scrollback.
Its parsers and input encoders also work standalone. "The C ABI is stable from
1.0."

It has **no renderer, no PTY, no GTK widget and no VTE-compatible API.** Those
are ours to write. nixpkgs-unstable carries `libghostty-vt` at
`0.1.0-unstable-2026-08-06`, which predates the stable ABI.

## Current state

`modules/desktop/pantheon-terminal.nix` installs elementary Terminal 8.1.0
built against `vte-gtk4` carrying `_vte-osc52-clipboard.patch` (OSC 52 writes
only; reads never answered). The `desktop` feature imports it.

In elementary Terminal, `TerminalWidget` (1,166 lines) subclasses
`Vte.Terminal`. The rest of the app (about 3,800 lines of Vala in total) reaches
VTE through that subclass and a small set of calls: `spawn_async`,
`feed_child`, `get_text_range_format`, `get_cursor_position`,
`search_set_regex`/`search_set_wrap_around`, `match_*`, `copy_clipboard`/
`paste_clipboard` overrides, `select_all`/`unselect_all`, `reset`,
`increase_font_size`/`decrease_font_size`, `get_char_height`, and the
`contents_changed`, `child_exited`, `window_title_changed` and
`selection_changed` signals, plus `Vte.Regex`, `Vte.CursorShape`,
`Vte.Format`, `Vte.PtyFlags` and `Vte.get_user_shell`.

## Approach

A Vala GTK4 widget library, `gvt`, whose public API copies the subset of
`Vte.Terminal` elementary uses, backed by libghostty-vt and drawn with
GtkSnapshot. elementary Terminal is then patched to subclass it.

Rejected:

- **Embedding the full Ghostty engine** (`ghostty.h` surface API, as the macOS
  app does) in a `GtkGLArea`. It would give Ghostty's renderer, fonts and input
  for free, but that API is internal, unversioned and not supported for Linux
  embedding; the weekly update routine would meet its breakage unattended.
- **Writing the widget in C or Zig.** Same design, more GObject boilerplate,
  and a different language from the app it serves.

## Components

All source lives in this repository.

### 1. `packages/libghostty-vt/`

libghostty-vt 1.0.0 built from the official release tarballs,
`https://release.files.ghostty.org/libghostty-vt/1.0.0/libghostty-vt-1.0.0.tar.gz`
and its `-deps.tar.gz`, as `PACKAGING-LIBGHOSTTY.md` at tag `vt-1.0.0`
prescribes (`zig build --system <deps>`, fresh `ZIG_GLOBAL_CACHE_DIR`). It
needs Zig **0.17.0**, taken from `pkgs.unstable.zig_0_17` because stable
nixpkgs (blackbird) stops at 0.16. Outputs the shared library, `ghostty/vt.h`
and `libghostty-vt.pc`. Pinned by hash, so `nix flake update` cannot move it.
Nothing outside this package knows about Zig. The package name deliberately
shadows nixpkgs-unstable's `libghostty-vt` (0.1.0-unstable) inside our
overlay.

### 2. `packages/gvt/`

Vala + GTK4 library, built with meson. Ships `gvt.vapi` and `gvt.pc`.

Public API: `Gvt.Terminal : Gtk.Widget`, `Gvt.Regex`, and enums
`Gvt.CursorShape`, `Gvt.Format`, `Gvt.PtyFlags`, plus `Gvt.get_user_shell()`,
all with VTE's names and signatures. **Only the API elementary uses is
copied**; a call the port turns out to need is added then, not in advance.

Internal units, each its own class:

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `Engine` | The only code touching the libghostty C API (via a handwritten `ghostty-vt.vapi`): write bytes, resize, read cells/cursor/dirty rows, terminal events, text export | libghostty-vt |
| `Pty` | `openpty`/fork/exec, nonblocking reads on the GLib main loop, `TIOCSWINSZ`, child watch and exit status | GLib, Posix |
| `Renderer` | GtkSnapshot + Pango; one cached render node per row, invalidated by dirty rows; cursor; colors and palette | Engine, Pango, GSK |
| `Selection` | Mouse gestures onto libghostty's selection API (`ghostty_selection_gesture_*`, `ghostty_terminal_select_*`); selected text via the formatter | Engine |
| `Input` | GTK key and mouse events to bytes, through libghostty's key/mouse encoders (honours kitty, application cursor, mouse reporting modes); bracketed paste | Engine |
| `Search` | VTE's find-bar API over `ghostty_search_*` (literal, case-insensitive, scrollback included); URL matching (`match_add_regex`, `check_match_at`) with `GLib.Regex` over the row under the pointer | Engine, GLib |
| `Clipboard` | OSC 52 writes, and reads gated by a setting, through `Gdk.Clipboard` | Engine, GDK |

### 3. `packages/elementary-terminal-ghostty/`

`pkgs.pantheon.elementary-terminal`, pinned to source tag **8.1.0** (raider's
unstable nixpkgs has 8.1.0 but blackbird's stable has 8.0.0, and one patch
must apply everywhere; stable's granite 7.8.1 and GTK 4.22 satisfy 8.1.0's
meson requirements), with `vte-gtk4` replaced by `gvt` in its inputs and a patch that changes `TerminalWidget`'s base class from
`Vte.Terminal` to `Gvt.Terminal`, swaps the `Vte.*` symbols for their `Gvt.*`
equivalents, switches the meson dependency, and drops the
`GLib.Regex.escape_string` in `SearchToolbar.vala` (gvt's find bar searches
literally already). A patch, not a copy of the
source, so upstream releases still apply and the diff is exactly the port. The
patch's header lists the files and hunks it touches, as
`pantheon-terminal.nix` does for the VTE patch, so whoever rebases it after a
bump knows where to look.

### 4. `modules/desktop/pantheon-terminal.nix`

Installs `elementary-terminal-ghostty` in place of the VTE build (keeping the
`environment.pantheon.excludePackages` swap) and deletes
`_vte-osc52-clipboard.patch`. Its header comment is rewritten to describe the
new arrangement.

## Data flow

**Output.** The child writes to the PTY. `Pty` reads up to 64 KiB per wakeup on
the main loop and hands the bytes to `Engine` (`ghostty_terminal_vt_write`).
`Engine` reports dirty rows; `Renderer` drops those rows' cached nodes and
requests one redraw per frame through the frame clock, never per read, so a
burst of output costs one redraw. While synchronized output (mode 2026) is
active, redraws are held until it ends.

**Events.** Title, working directory (OSC 7), bell, OSC 52 and hyperlinks are
emitted as VTE-named signals and properties (`window_title_changed`,
`current_directory_uri`, `bell`, `contents_changed`, …), so elementary's
handlers are unchanged.

**Input.** A key event goes through libghostty's key encoder, which applies
whatever modes the running program enabled, and the bytes are written to the
PTY. Mouse events are encoded when mouse reporting is on, and drive
`Selection` otherwise. Paste is wrapped in bracketed-paste markers when that
mode is on; elementary's unsafe-paste dialog still runs first, because it
overrides `paste_clipboard`.

**Scrolling.** `Gvt.Terminal` implements `Gtk.Scrollable`, as VTE does,
because elementary wraps it in a `Gtk.ScrolledWindow` bound to its
`vadjustment`. The adjustment counts rows (VTE's unit); `scroll_unit_is_pixels`
is accepted and stored but does not change that.

**Resize.** Rows and columns come from the widget's allocation and the font's
cell metrics; `Engine` resizes the terminal and `Pty` sends `TIOCSWINSZ`.

## Failure handling

- `forkpty`/`exec` failure: `spawn_async` reports the error through its
  callback, the same contract as VTE; elementary already surfaces it.
- PTY EOF or EIO: emit `child_exited` with the status from `waitpid`.
- libghostty allocation failure: logged with `critical`, and that one tab
  closes; the window and other tabs survive.
- **OSC 52 reads are off by default**, behind a GSettings key. Answering them
  lets any program in the terminal, including one at the far end of an SSH
  session, read the local clipboard. OSC 52 writes are always on, as today.

## Testing

**Unit tests, as the build's `doCheck`**, under a headless Weston
(`weston --backend=headless`), so they run in the sandbox and in CI (which
builds raider):

- `Engine`: known byte streams produce the expected cells, cursor, title, cwd.
- `Pty`: spawn `sh -c 'printf …; exit 3'`, read the output, receive
  `child_exited(3)`; a resize is visible to `stty size`.
- `Input`: key events produce the expected bytes in legacy, application-cursor
  and kitty modes.
- `Selection` and `Search`: selection across wrapped lines copies the right
  text; regexes match.
- `Renderer`: a known screen rendered to a texture has the expected size and
  colors at sampled cells. No pixel-golden images; they break on font changes.

**One end-to-end NixOS VM test** in `modules/flake/checks.nix`: start the
patched elementary Terminal in a headless Wayland session, run a script that
prints an OSC 52 copy, a title and a colored line, and assert that `wl-paste`
returns the copied text and the window title changed. This is also the
regression test for the OSC 52 behaviour the VTE patch provides today.

**Manual parity checklist** before the switch, on raider:

- [ ] tabs, and tab restore after restart
- [ ] search toolbar (next/previous, regex, wrap-around)
- [ ] URL hover and click
- [ ] copy last output; clear screen; reset; select all
- [ ] zoom in/out/reset
- [ ] theme, palette, cursor shape and dark-style settings
- [ ] foreground-process warning when closing a busy tab
- [ ] drag and drop of files
- [ ] unsafe-paste dialog
- [ ] zellij, nvim and Claude Code, locally and over SSH, including OSC 52 copy
- [ ] large output (`seq 1 5000000`) stays responsive, no worse than VTE

## Rollout

1. Iterate on raider with `just test raider`, which does not change the boot
   default.
2. Once the checklist passes, one commit makes `pantheon-terminal.nix` install
   the new build on every host with the `desktop` feature and deletes the VTE
   OSC 52 patch.
3. Rollback is reverting that commit. There is no runtime switch.

## Weekly update interaction

libghostty-vt is pinned to its 1.0 tag and its ABI is stable, so the routine's
`nix flake update` cannot move it. An elementary Terminal bump that breaks the
patch fails the build; the routine already fixes or reverts such breakage, and
the patch header tells it where to look.

## Out of scope

- A `GtkGLArea`/custom GL renderer. Considered only if profiling shows GSK
  drawing is the bottleneck; it would replace `Renderer` without touching the
  public API.
- Kitty graphics, sixel and other image protocols.
- Accessibility (AT-SPI text interface) beyond what GTK gives a plain widget.
  VTE has it; gvt v1 does not. Noted as a known regression.
- Upstreaming anything to elementary or Ghostty.
