/*
 * Search: the find bar (Terminal.search_*), and Matcher: the clickable
 * patterns (Terminal.match_*), both with VTE's behaviour.
 *
 * Search is libghostty's: literal, case-insensitive, over the scrollback
 * too. While a needle is set, it is kept up to date from a low-priority
 * idle, a slice at a time, starting when the needle is set and again after
 * each batch of output, so a big scrollback never holds up a frame.
 *
 * Directions are VTE's: find_next moves down, toward newer output, and
 * starts at the top of the scrollback; find_previous moves up and starts at
 * the bottom. libghostty indexes matches the other way round (0 is the
 * newest) and always wraps, so the ends are checked here when wrap-around
 * is off. A find first finishes whatever searching is left, synchronously,
 * as VTE's own search does: the first match from the top is not known until
 * the whole scrollback has been seen. The found match becomes the
 * terminal's selection, and libghostty scrolls it into view.
 */
namespace Gvt {
    internal class Search : Object {
        /* How long one idle dispatch may search for. */
        private const int64 SLICE_US = 2000;

        private unowned Terminal terminal;
        private bool active = false;
        private bool wrap_around = false;
        /* Output arrived since the search last saw the terminal. */
        private bool changed = false;
        private uint idle_id = 0;

        public Search (Terminal terminal) {
            this.terminal = terminal;
        }

        /* Null, or an empty pattern, ends the search. */
        public void set_regex (Regex? regex) {
            var needle = regex != null ? regex.literal : null;
            active = needle != null && needle != "";
            terminal.engine.search_set_needle (active ? needle : null);
            if (active) {
                schedule ();
            } else {
                stop ();
            }
        }

        public void set_wrap_around (bool wrap) {
            wrap_around = wrap;
        }

        /* The terminal's contents changed. */
        public void contents_changed () {
            if (active) {
                changed = true;
                schedule ();
            }
        }

        /* Down (newer) for next, up (older) for previous. */
        public bool find (bool older) {
            if (!active) {
                return false;
            }
            var engine = terminal.engine;
            stop ();
            changed = false;
            engine.search_finish ();
            var total = engine.search_total;
            if (total == 0) {
                return false;
            }
            size_t index = 0;
            if (!wrap_around && engine.search_selected_index (out index)) {
                if (older ? index + 1 >= total : index == 0) {
                    return false;
                }
            }
            if (!engine.search_select (older) || !engine.search_show_selected ()) {
                return false;
            }
            terminal.search_selected ();
            return true;
        }

        public void stop () {
            if (idle_id != 0) {
                Source.remove (idle_id);
                idle_id = 0;
            }
        }

        private void schedule () {
            if (idle_id == 0) {
                idle_id = Idle.add (step, Priority.LOW);
            }
        }

        private bool step () {
            var was_changed = changed;
            changed = false;
            if (terminal.engine.search_step (was_changed, SLICE_US)) {
                idle_id = 0;
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        }
    }

    /*
     * The patterns registered with match_add_regex (), tried in the order
     * they were added, over the text of the line under the pointer: its
     * row and the rows soft-wrapped onto it, so a long URL is one match. A
     * hard line break ends a line.
     */
    internal class Matcher : Object {
        private class Entry {
            public int tag;
            public GLib.Regex regex;
            public string? cursor_name = null;
        }

        /* How far a soft-wrapped line is followed either way. */
        private const int MAX_WRAPPED_ROWS = 64;

        private unowned Terminal terminal;
        private List<Entry> entries = new List<Entry> ();
        private int next_tag = 0;

        public Matcher (Terminal terminal) {
            this.terminal = terminal;
            var motion = new Gtk.EventControllerMotion ();
            motion.motion.connect (on_motion);
            motion.leave.connect (on_leave);
            terminal.add_controller (motion);
        }

        /* -1 for a pattern made with Regex.for_search, as VTE refuses it. */
        public int add (Regex regex) {
            return_val_if_fail (regex.compiled != null, -1);
            var entry = new Entry ();
            entry.tag = next_tag++;
            entry.regex = regex.compiled;
            entries.append (entry);
            return entry.tag;
        }

        public void set_cursor_name (int tag, string? cursor_name) {
            foreach (var entry in entries) {
                if (entry.tag == tag) {
                    entry.cursor_name = cursor_name;
                }
            }
        }

        public void remove_all () {
            entries = new List<Entry> ();
            terminal.set_cursor (null);
        }

        /* The match covering the cell at (x, y), widget pixels; tag is its
         * pattern's tag, -1 for none. */
        public string? check (double x, double y, out int tag) {
            unowned Entry? entry;
            var text = match_at (x, y, out entry);
            tag = entry != null ? entry.tag : -1;
            return text;
        }

        /* Shows the cursor of the match under (x, y), if any. */
        public void hover (double x, double y) {
            if (entries.length () == 0) {
                return;
            }
            unowned Entry? entry;
            match_at (x, y, out entry);
            terminal.set_cursor_from_name (entry != null ? entry.cursor_name : null);
        }

        private string? match_at (double x, double y, out unowned Entry? found) {
            found = null;
            if (entries.length () == 0) {
                return null;
            }
            var cw = double.max (terminal.get_char_width (), 1);
            var ch = double.max (terminal.get_char_height (), 1);
            var col = (long) Math.floor (x / cw);
            var row = (long) Math.floor (y / ch);
            var engine = terminal.engine;
            if (col < 0 || col >= engine.cols || row < 0 || row >= engine.rows) {
                return null;
            }
            // The whole soft-wrapped line the cell is in, so a URL longer
            // than the terminal is wide is still one match.
            var abs_row = engine.viewport_top + row;
            var first = abs_row;
            while (first > abs_row - MAX_WRAPPED_ROWS && engine.row_wrapped (first - 1)) {
                first--;
            }
            var last = abs_row;
            while (last < abs_row + MAX_WRAPPED_ROWS && engine.row_wrapped (last)) {
                last++;
            }
            var line = new StringBuilder ();
            var at = -1;
            for (var r = first; r <= last; r++) {
                int[] offsets;
                var text = engine.row_text (r, out offsets);
                if (r == abs_row) {
                    if (offsets.length <= col) {
                        return null;
                    }
                    at = (int) line.len + offsets[col];
                }
                line.append (text);
            }
            if (at < 0) {
                return null;
            }
            var text = line.str;
            foreach (unowned Entry entry in entries) {
                MatchInfo info;
                if (!entry.regex.match (text, 0, out info)) {
                    continue;
                }
                while (info.matches ()) {
                    int start, end;
                    if (info.fetch_pos (0, out start, out end) && start <= at && at < end) {
                        found = entry;
                        return info.fetch (0);
                    }
                    try {
                        info.next ();
                    } catch (RegexError e) {
                        break;
                    }
                }
            }
            return null;
        }

        private void on_motion (Gtk.EventControllerMotion controller, double x, double y) {
            hover (x, y);
        }

        private void on_leave () {
            if (entries.length () > 0) {
                terminal.set_cursor (null);
            }
        }
    }
}
