/*
 * Clipboard: OSC 52 between the program and the display clipboard.
 *
 * Writes are always honoured: Engine.clipboard_write goes straight to the
 * display clipboard.
 *
 * Reads must be answered synchronously, inside the Engine's signal, and
 * Gdk.Clipboard can only be read asynchronously. So a copy of the display
 * clipboard's text is kept and reads are answered from it. The copy is
 * refreshed whenever the clipboard changes, but only while the
 * io.github.arsfeld.gvt key clipboard-read is true (off by default, and then
 * nothing is read); text the user pastes is kept too. A read the user
 * already granted (the follow-up of a Kitty paste event) is always answered;
 * a plain OSC 52 read only when clipboard-read is true. Otherwise, or when
 * the schema is not installed, the program is refused and libghostty tells it
 * the clipboard is empty. Only text is offered.
 */
namespace Gvt {
    internal class Clipboard : Object {
        private const string SCHEMA = "io.github.arsfeld.gvt";
        private const string KEY = "clipboard-read";

        private Gdk.Clipboard display_clipboard;
        /* Bumped per refresh, so a slow read never overwrites a newer one. */
        private uint serial = 0;
        private GLib.Settings? settings = null;
        private bool settings_looked_up = false;

        /* The display clipboard's text, as last read; null if it has none
         * or it was not read. */
        internal string? cached { get; private set; default = null; }
        /* Reads of the display clipboard started so far. */
        internal uint reads { get; private set; default = 0; }

        public Clipboard (Terminal terminal) {
            display_clipboard = terminal.get_clipboard ();
            display_clipboard.changed.connect (on_changed);
            terminal.engine.clipboard_write.connect (on_write);
            terminal.engine.clipboard_read_requested.connect (on_read_requested);
            on_changed ();
        }

        /* Text the user pastes: the clipboard as it is now, which a Kitty
         * paste event's granted follow-up read is answered with. */
        internal void remember (string text) {
            serial++;
            cached = text;
        }

        /* Reads the new contents only if programs may read them; otherwise
         * forgets the old ones. */
        private void on_changed () {
            if (read_allowed ()) {
                refresh ();
            } else {
                serial++;
                cached = null;
            }
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
                // A missing schema, or a stale compiled one without the key,
                // would abort the process in GSettings: refuse reads instead.
                var source = SettingsSchemaSource.get_default ();
                var schema = source != null ? source.lookup (SCHEMA, true) : null;
                if (schema != null && schema.has_key (KEY)) {
                    settings = new GLib.Settings (SCHEMA);
                    settings.changed[KEY].connect (on_changed);
                }
            }
            return settings != null && settings.get_boolean (KEY);
        }

        private void refresh () {
            var mine = ++serial;
            reads++;
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
