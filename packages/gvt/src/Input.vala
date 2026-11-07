/*
 * Input: what the user does, turned into bytes for the child.
 *
 * Keys: a Gtk.EventControllerKey in the bubble phase, so a subclass's own
 * key controller (elementary's, which runs in the capture phase) sees every
 * key first, and a key this produces no bytes for propagates on. Each press
 * goes through the input method first. While it has a pre-edit (a dead key,
 * compose, IBus mid-word), keys are the IM's alone and send nothing; text it
 * commits outside a key event is written as UTF-8. Text it commits for a
 * plain key is encoded as that key, so Kitty-mode programs still see the key.
 *
 * Mouse: while the program has mouse tracking on, clicks, motion and the
 * wheel are encoded for it. Otherwise presses, drags and releases go to
 * selection_event (Task 6's Selection) and the wheel scrolls the
 * vadjustment. A press and its drag and release stay with whichever of the
 * two got the press. libghostty's mouse encoder has no alternate-scroll
 * (wheel to arrow keys) mode, so the wheel never becomes keys.
 *
 * Focus: reported to a program that set mode 1004, and redraws the cursor.
 *
 * Every byte goes out through send (), which emits `sent`.
 */
namespace Gvt {
    internal enum PointerPhase { PRESS, DRAG, RELEASE }

    /* The key-event accessors take a GdkEvent in C; gtk4.vapi binds them on
     * Gdk.KeyEvent, whose pointer type C then warns about. */
    [CCode (cname = "gdk_key_event_get_consumed_modifiers")]
    private extern Gdk.ModifierType key_event_consumed (Gdk.Event event);
    [CCode (cname = "gdk_key_event_get_layout")]
    private extern uint key_event_layout (Gdk.Event event);

    internal class Input : Object {
        private enum Owner { NONE, PROGRAM, SELECTION }

        private unowned Terminal terminal;
        private Gtk.IMContext im_context;
        private ulong commit_handler = 0;
        private ulong preedit_handler = 0;
        private string preedit = "";
        /* Collects what the IM commits while it filters a key press. */
        private StringBuilder? key_commit = null;
        /* Hardware keycodes held down, to tell a repeat from a press. */
        private GenericSet<uint> held_keys = new GenericSet<uint> (direct_hash, direct_equal);

        private uint held_buttons = 0;
        private Owner pointer_owner = Owner.NONE;
        private double pointer_x = 0;
        private double pointer_y = 0;
        private long last_motion_col = -1;
        private long last_motion_row = -1;
        private double scroll_rest = 0;

        /* Every byte Input sends the child, as it is sent. */
        public signal void sent (uint8[] bytes);

        /* Pointer input that is not the program's: col is clamped to the
         * screen, row is absolute (viewport_top + viewport row, so it can be
         * above or below the viewport while dragging). n_press is the click
         * count of the press (2 = double click); DRAG and RELEASE repeat it. */
        public signal void selection_event (PointerPhase phase, long col, long row, uint button,
                                            Gdk.ModifierType state, int n_press);

        private int n_press = 1;

        public Input (Terminal terminal) {
            this.terminal = terminal;

            var keys = new Gtk.EventControllerKey ();
            keys.propagation_phase = Gtk.PropagationPhase.BUBBLE;
            keys.key_pressed.connect (on_key_pressed);
            keys.key_released.connect (on_key_released);
            terminal.add_controller (keys);

            var focus = new Gtk.EventControllerFocus ();
            focus.enter.connect (on_focus_enter);
            focus.leave.connect (on_focus_leave);
            terminal.add_controller (focus);

            var click = new Gtk.GestureClick ();
            click.button = 0;
            click.pressed.connect (on_pressed);
            terminal.add_controller (click);

            // Releases and held motion come from a drag gesture, which, unlike
            // a click gesture, does not give up once the pointer moves.
            var drag = new Gtk.GestureDrag ();
            drag.button = 0;
            drag.drag_update.connect (on_drag_update);
            drag.drag_end.connect (on_drag_end);
            terminal.add_controller (drag);

            var motion = new Gtk.EventControllerMotion ();
            motion.motion.connect (on_motion);
            terminal.add_controller (motion);

            var scroller = new Gtk.EventControllerScroll (Gtk.EventControllerScrollFlags.VERTICAL);
            scroller.scroll.connect (on_scroll);
            terminal.add_controller (scroller);

            im = new Gtk.IMMulticontext ();
        }

        /* The input method; replaceable, for tests. */
        public Gtk.IMContext im {
            get { return im_context; }
            set {
                if (im_context != null) {
                    im_context.disconnect (commit_handler);
                    im_context.disconnect (preedit_handler);
                    im_context.set_client_widget (null);
                }
                im_context = value;
                im_context.set_client_widget (terminal);
                commit_handler = im_context.commit.connect (on_commit);
                preedit_handler = im_context.preedit_changed.connect (on_preedit_changed);
                preedit = "";
            }
        }

        /* Drops the IM's hold on the widget; Terminal.dispose calls it. */
        public void detach () {
            im_context.set_client_widget (null);
        }

        /* ---- keys ---- */

        /* Encodes one key event and sends it. True if it was sent, or the IM
         * owns the key (pre-edit active); false lets it propagate. */
        public bool key (GhosttyVt.Key key, GhosttyVt.KeyAction action, GhosttyVt.Mods mods,
                         string? utf8, unichar unshifted, GhosttyVt.Mods consumed = 0) {
            if (preedit != "") {
                return true;
            }
            var bytes = terminal.engine.encode_key (key, action, mods, utf8, unshifted, consumed);
            if (bytes.length == 0) {
                return false;
            }
            send (bytes, true);
            return true;
        }

        private bool on_key_pressed (Gtk.EventControllerKey controller, uint keyval, uint keycode,
                                     Gdk.ModifierType state) {
            var action = keycode in held_keys ? GhosttyVt.KeyAction.REPEAT : GhosttyVt.KeyAction.PRESS;
            held_keys.add (keycode);
            unowned Gdk.Event? event = controller.get_current_event ();

            bool was_composing = preedit != "";
            update_im_cursor ();
            key_commit = new StringBuilder ();
            bool filtered = event != null && im_context.filter_keypress (event);
            var committed = key_commit.str;
            key_commit = null;

            if (filtered) {
                if (was_composing || preedit != "" || committed == "") {
                    // Composition: the IM's text, or nothing yet.
                    if (committed != "") {
                        send (committed.data, true);
                    }
                    return true;
                }
                // The IM passed a plain key's text through.
                if (!key (Keymap.from_gdk (keycode), action, mods_of (state, event), committed,
                          unshifted_of (event, keycode, keyval), consumed_of (event))) {
                    send (committed.data, true);
                }
                return true;
            }
            return key (Keymap.from_gdk (keycode), action, mods_of (state, event), text_of (keyval),
                        unshifted_of (event, keycode, keyval), consumed_of (event));
        }

        private void on_key_released (Gtk.EventControllerKey controller, uint keyval, uint keycode,
                                      Gdk.ModifierType state) {
            held_keys.remove (keycode);
            unowned Gdk.Event? event = controller.get_current_event ();
            if (event != null && im_context.filter_keypress (event)) {
                return;
            }
            key (Keymap.from_gdk (keycode), GhosttyVt.KeyAction.RELEASE, mods_of (state, event),
                 text_of (keyval), unshifted_of (event, keycode, keyval), consumed_of (event));
        }

        private void on_commit (string text) {
            if (key_commit != null) {
                key_commit.append (text);
            } else if (text != "") {
                send (text.data, true);
            }
        }

        private void on_preedit_changed () {
            string text;
            Pango.AttrList attrs;
            int cursor;
            im_context.get_preedit_string (out text, out attrs, out cursor);
            preedit = text ?? "";
        }

        /* Places IM popups at the cursor. */
        private void update_im_cursor () {
            long col, row;
            terminal.engine.cursor (out col, out row);
            var cw = (int) terminal.get_char_width ();
            var ch = (int) terminal.get_char_height ();
            Gdk.Rectangle rect = {
                (int) col * cw, (int) (row - terminal.engine.viewport_top) * ch, cw, ch
            };
            im_context.set_cursor_location (rect);
        }

        private static GhosttyVt.Mods mods_of (Gdk.ModifierType state, Gdk.Event? event) {
            GhosttyVt.Mods mods = to_mods (state);
            var device = event != null ? event.get_device () : null;
            if (device != null && device.num_lock_state) {
                mods |= GhosttyVt.Mods.NUM_LOCK;
            }
            return mods;
        }

        private static GhosttyVt.Mods consumed_of (Gdk.Event? event) {
            return event != null ? to_mods (key_event_consumed (event)) : 0;
        }

        private static GhosttyVt.Mods to_mods (Gdk.ModifierType state) {
            GhosttyVt.Mods mods = 0;
            if (Gdk.ModifierType.SHIFT_MASK in state) {
                mods |= GhosttyVt.Mods.SHIFT;
            }
            if (Gdk.ModifierType.CONTROL_MASK in state) {
                mods |= GhosttyVt.Mods.CTRL;
            }
            if (Gdk.ModifierType.ALT_MASK in state) {
                mods |= GhosttyVt.Mods.ALT;
            }
            if (Gdk.ModifierType.SUPER_MASK in state) {
                mods |= GhosttyVt.Mods.SUPER;
            }
            if (Gdk.ModifierType.LOCK_MASK in state) {
                mods |= GhosttyVt.Mods.CAPS_LOCK;
            }
            return mods;
        }

        /* The key's text for the layout; null for none or a control char. */
        private static string? text_of (uint keyval) {
            var c = (unichar) Gdk.keyval_to_unicode (keyval);
            if (c == 0 || c < 0x20 || c == 0x7f) {
                return null;
            }
            return c.to_string ();
        }

        /* The character the key gives with no modifiers, in its layout. */
        private unichar unshifted_of (Gdk.Event? event, uint keycode, uint keyval) {
            uint base_keyval = keyval;
            if (event != null) {
                uint translated;
                int group, level;
                Gdk.ModifierType consumed;
                if (terminal.get_display ().translate_key (keycode, 0, (int) key_event_layout (event),
                                                           out translated, out group, out level,
                                                           out consumed)) {
                    base_keyval = translated;
                }
            }
            return (unichar) Gdk.keyval_to_unicode (base_keyval);
        }

        /* ---- mouse ---- */

        /* A button pressed (press) or released at (x, y), widget pixels. */
        public void button (bool press, uint button, double x, double y, Gdk.ModifierType state,
                            int clicks) {
            pointer_x = x;
            pointer_y = y;
            var bit = button < 32 ? 1u << button : 0u;
            if (press) {
                terminal.grab_focus ();
                if (held_buttons == 0) {
                    pointer_owner = terminal.engine.mouse_tracking ? Owner.PROGRAM : Owner.SELECTION;
                    n_press = clicks;
                }
                held_buttons |= bit;
            } else {
                held_buttons &= ~bit;
            }
            var owner = pointer_owner;
            if (held_buttons == 0) {
                pointer_owner = Owner.NONE;
            }

            if (owner == Owner.PROGRAM) {
                send_mouse (press ? GhosttyVt.MouseAction.PRESS : GhosttyVt.MouseAction.RELEASE,
                            to_button (button), state);
            } else if (owner == Owner.SELECTION) {
                long col, row;
                cell_at (x, y, out col, out row);
                selection_event (press ? PointerPhase.PRESS : PointerPhase.RELEASE, col, row, button,
                                 state, n_press);
            }
        }

        /* The pointer moved to (x, y), with or without buttons held. */
        public void motion (double x, double y, Gdk.ModifierType state) {
            pointer_x = x;
            pointer_y = y;
            long col, row;
            cell_at (x, y, out col, out row);
            if (pointer_owner == Owner.SELECTION) {
                selection_event (PointerPhase.DRAG, col, row, held_button (), state, n_press);
                return;
            }
            if (!terminal.engine.mouse_tracking) {
                return;
            }
            // One report per cell, as VTE sends.
            if (col == last_motion_col && row == last_motion_row) {
                return;
            }
            last_motion_col = col;
            last_motion_row = row;
            send_mouse (GhosttyVt.MouseAction.MOTION, to_button (held_button ()), state);
        }

        /* Scrolls by dy wheel steps, or dy pixels when `pixels`; negative
         * is up. Always handled. */
        public bool scroll (double dy, bool pixels) {
            scroll_rest += pixels ? dy / double.max (terminal.get_char_height (), 1) : dy;
            var steps = (int) scroll_rest;
            scroll_rest -= steps;
            if (steps == 0) {
                return true;
            }
            if (terminal.engine.mouse_tracking) {
                var wheel = steps < 0 ? GhosttyVt.MouseButton.FOUR : GhosttyVt.MouseButton.FIVE;
                for (var i = 0; i < steps.abs (); i++) {
                    send_mouse (GhosttyVt.MouseAction.PRESS, wheel, 0);
                }
                return true;
            }
            // VTE's step: a tenth of a page, at least a row.
            var adj = terminal.vadjustment;
            var rows = double.max (Math.ceil (adj.page_size / 10), 1);
            adj.value = adj.value + steps * rows;
            return true;
        }

        private void send_mouse (GhosttyVt.MouseAction action, GhosttyVt.MouseButton button,
                                 Gdk.ModifierType state) {
            var bytes = terminal.engine.encode_mouse (
                action, button, to_mods (state), (float) pointer_x, (float) pointer_y,
                terminal.get_width (), terminal.get_height (),
                (uint32) terminal.get_char_width (), (uint32) terminal.get_char_height (),
                held_buttons != 0);
            if (bytes.length > 0) {
                send (bytes, false);
            }
        }

        /* The lowest held button (primary first), or 0. */
        private uint held_button () {
            for (uint b = 1; b < 32; b++) {
                if ((held_buttons & (1u << b)) != 0) {
                    return b;
                }
            }
            return 0;
        }

        /* GDK buttons are X11's: 1 left, 2 middle, 3 right, then 4 up. */
        private static GhosttyVt.MouseButton to_button (uint button) {
            switch (button) {
            case 1:
                return GhosttyVt.MouseButton.LEFT;
            case 2:
                return GhosttyVt.MouseButton.MIDDLE;
            case 3:
                return GhosttyVt.MouseButton.RIGHT;
            default:
                return button >= 4 && button <= 11
                    ? (GhosttyVt.MouseButton) button
                    : GhosttyVt.MouseButton.UNKNOWN;
            }
        }

        private void cell_at (double x, double y, out long col, out long row) {
            var cw = double.max (terminal.get_char_width (), 1);
            var ch = double.max (terminal.get_char_height (), 1);
            col = ((long) Math.floor (x / cw)).clamp (0, (long) terminal.engine.cols - 1);
            row = terminal.engine.viewport_top + (long) Math.floor (y / ch);
        }

        private void on_pressed (Gtk.GestureClick gesture, int clicks, double x, double y) {
            button (true, gesture.get_current_button (), x, y, gesture.get_current_event_state (), clicks);
        }

        private void on_drag_update (Gtk.GestureDrag gesture, double dx, double dy) {
            double x, y;
            gesture.get_start_point (out x, out y);
            motion (x + dx, y + dy, gesture.get_current_event_state ());
        }

        private void on_drag_end (Gtk.GestureDrag gesture, double dx, double dy) {
            double x, y;
            gesture.get_start_point (out x, out y);
            button (false, gesture.get_current_button (), x + dx, y + dy,
                    gesture.get_current_event_state (), n_press);
        }

        private void on_motion (Gtk.EventControllerMotion controller, double x, double y) {
            // Held motion is the drag gesture's.
            if (held_buttons == 0) {
                motion (x, y, controller.get_current_event_state ());
            }
        }

        private bool on_scroll (Gtk.EventControllerScroll controller, double dx, double dy) {
            return scroll (dy, controller.get_unit () == Gdk.ScrollUnit.SURFACE);
        }

        /* ---- paste and focus ---- */

        public void paste (string text) {
            var bytes = terminal.engine.encode_paste (text);
            if (bytes.length > 0) {
                send (bytes, true);
            }
        }

        public void focus_changed (bool focused) {
            if (focused) {
                im_context.focus_in ();
            } else {
                im_context.focus_out ();
            }
            if (terminal.engine.mode (1004)) {
                send (terminal.engine.encode_focus (focused), false);
            }
            // The cursor is hollow without focus.
            terminal.queue_draw ();
        }

        private void on_focus_enter () {
            focus_changed (true);
        }

        private void on_focus_leave () {
            focus_changed (false);
        }

        /* typed: what the user types or pastes, which brings the viewport
         * back to the bottom, as VTE's scroll-on-keystroke does. */
        private void send (uint8[] bytes, bool typed) {
            if (typed) {
                terminal.scroll_to_bottom ();
            }
            sent (bytes);
            terminal.feed_child (bytes);
        }
    }
}
