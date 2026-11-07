/*
 * Selection: the mouse and the VTE selection calls, onto the selection
 * libghostty holds in the Engine.
 *
 * Primary-button presses, drags and releases from Input.selection_event go
 * through Engine.gesture (): a single click selects by cell, a double click by
 * word, a triple click by line. Other buttons are left alone. When a mouse
 * selection ends with something selected, it goes to the primary clipboard,
 * as X11 terminals do.
 *
 * Every change redraws and emits Terminal.selection_changed. Text is what
 * Engine.selection_text () gives: soft-wrapped rows joined, hard line breaks
 * as "\n", trailing blanks trimmed, as in VTE.
 */
namespace Gvt {
    internal class Selection : Object {
        private unowned Terminal terminal;

        public Selection (Terminal terminal) {
            this.terminal = terminal;
            terminal.input.selection_event.connect (on_selection_event);
        }

        public void select_all () {
            terminal.engine.select_all ();
            changed ();
        }

        public void unselect_all () {
            if (!terminal.engine.has_selection) {
                return;
            }
            terminal.engine.clear_selection ();
            changed ();
        }

        /* The selected text; null when nothing is selected. */
        public string? text () {
            return terminal.engine.selection_text ();
        }

        private void on_selection_event (PointerPhase phase, long col, long row, uint button,
                                         Gdk.ModifierType state, int n_press, double x, double y) {
            if (button != Gdk.BUTTON_PRIMARY) {
                return;
            }
            SelectionGestureEvent ev = {
                phase, col, row, x, y, n_press,
                (uint32) terminal.get_char_width (), (uint32) int.max (terminal.get_height (), 0)
            };
            if (terminal.engine.gesture (ev)) {
                changed ();
            }
            if (phase == PointerPhase.RELEASE && terminal.engine.has_selection) {
                terminal.copy_primary ();
            }
        }

        private void changed () {
            terminal.queue_draw ();
            terminal.selection_changed ();
        }
    }
}
