/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Styling for every part of a stack: the dock tile's preview icons, the fan,
 * which has no popover chrome (pills and icons float over the desktop), and
 * the grid popover.
 */

namespace Dock.StackStyle {
    private const string CSS = """
        /* A soft outline, so white icons (a plain-text page) still read on the
         * light dock tile, the white grid and the desktop. Faint enough that
         * coloured icons look unchanged. */
        icongroup.stack image,
        image.stack-icon {
            -gtk-icon-shadow:
                0 0 1px alpha(black, 0.35),
                0 1px 2px alpha(black, 0.2);
        }

        popover.stack-fan > contents,
        popover.stack-fan > arrow {
            background: none;
            border: none;
            box-shadow: none;
            padding: 0;
        }

        .stack-fan-label {
            background: alpha(black, 0.72);
            color: white;
            border-radius: 9999px;
            padding: 4px 12px;
            box-shadow: 0 1px 3px alpha(black, 0.25);
        }

        button.stack-fan-item {
            background: none;
            border: none;
            box-shadow: none;
            padding: 0;
            min-height: 0;
            min-width: 0;
        }

        button.stack-fan-item:hover .stack-fan-label,
        button.stack-fan-item:focus-visible .stack-fan-label {
            background: @accent_color;
        }

        popover.stack-grid > contents {
            padding: 12px;
        }

        popover.stack-grid gridview {
            background: none;
        }

        popover.stack-grid gridview > child {
            padding: 9px 6px 6px 6px;
            margin: 3px;
            border-radius: 9px;
        }

        popover.stack-grid gridview > child:hover {
            background: alpha(currentColor, 0.07);
        }

        popover.stack-grid gridview > child:focus-visible {
            background: alpha(@accent_color, 0.15);
        }

        /* Upstream Launcher's progress bar (data/Application.css), for stack
         * tiles, fan rows and grid cells. */
        progressbar.stack-progress {
            margin: 0 6px 4px 6px;
        }

        progressbar.stack-progress trough {
            background: #333;
            border: none;
            border-radius: 99px;
            box-shadow: none;
            min-height: 3px;
            padding: 1px;
        }

        progressbar.stack-progress progress {
            background: white;
            border: none;
            border-radius: 99px;
            box-shadow: none;
            margin: 0;
            min-height: 3px;
            min-width: 0;
        }

        icongroup.stack progressbar.stack-progress {
            margin-bottom: 6px;
        }

        .stack-status {
            font-size: smaller;
            opacity: 0.7;
        }

        .stack-folder-icon {
            background: alpha(currentColor, 0.08);
            border-radius: 12px;
            padding: 2px;
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
