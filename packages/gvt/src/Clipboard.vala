/*
 * Clipboard: OSC 52 between the program and the display clipboard.
 *
 * Writes are always honoured: Engine.clipboard_write goes straight to the
 * display clipboard.
 *
 * Reads must be answered synchronously, inside the Engine's signal, and
 * Gdk.Clipboard can only be read asynchronously. So a copy of the display
 * clipboard's text is kept, refreshed whenever the clipboard changes, and
 * reads are answered from it. A read the user already granted (the follow-up
 * of a Kitty paste event) is always answered; a plain OSC 52 read only when
 * the io.github.arsfeld.gvt key clipboard-read is true. Otherwise, or when
 * the schema is not installed, the program is refused and libghostty tells it
 * the clipboard is empty. Only text is offered.
 */
namespace Gvt {
    internal class Clipboard : Object {
        private const string SCHEMA = "io.github.arsfeld.gvt";

        private Gdk.Clipboard display_clipboard;
        /* Bumped per refresh, so a slow read never overwrites a newer one. */
        private uint serial = 0;
        private GLib.Settings? settings = null;
        private bool settings_looked_up = false;

        /* The display clipboard's text, as last read; null if it has none. */
        internal string? cached { get; private set; default = null; }

        public Clipboard (Terminal terminal) {
            display_clipboard = terminal.get_clipboard ();
            display_clipboard.changed.connect (refresh);
            terminal.engine.clipboard_write.connect (on_write);
            terminal.engine.clipboard_read_requested.connect (on_read_requested);
            refresh ();
        }

        private void on_write (string text) {
            display_clipboard.set_text (text);
        }

        private void on_read_requested (bool granted, ClipboardReply reply) {
            if (granted || read_allowed ()) {
                reply (cached ?? "");
            } else {
                reply (null);
            }
        }

        private bool read_allowed () {
            if (!settings_looked_up) {
                settings_looked_up = true;
                var source = SettingsSchemaSource.get_default ();
                if (source != null && source.lookup (SCHEMA, true) != null) {
                    settings = new GLib.Settings (SCHEMA);
                }
            }
            return settings != null && settings.get_boolean ("clipboard-read");
        }

        private void refresh () {
            var mine = ++serial;
            display_clipboard.read_text_async.begin (null, (obj, res) => {
                string? text = null;
                try {
                    text = display_clipboard.read_text_async.end (res);
                } catch (Error e) {
                    // No text on the clipboard.
                }
                if (mine == serial) {
                    cached = text;
                }
            });
        }
    }
}
