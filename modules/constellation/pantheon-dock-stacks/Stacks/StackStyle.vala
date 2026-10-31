/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * The fan has no popover chrome: icons and pill labels float over the desktop.
 */

namespace Dock.StackStyle {
    private const string CSS = """
        popover.stack-fan > contents,
        popover.stack-fan > arrow {
            background: none;
            border: none;
            box-shadow: none;
            padding: 0;
        }

        .stack-fan-label {
            background: alpha(black, 0.7);
            color: white;
            border-radius: 9999px;
            padding: 3px 10px;
        }

        button.stack-fan-item {
            background: none;
            border: none;
            box-shadow: none;
            padding: 0;
        }

        button.stack-fan-item:hover .stack-fan-label,
        button.stack-fan-item:focus-visible .stack-fan-label {
            background: @accent_color;
        }
    """;

    private bool loaded = false;

    public void ensure () {
        if (loaded) {
            return;
        }
        loaded = true;

        var provider = new Gtk.CssProvider ();
        provider.load_from_string (CSS);
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }
}
