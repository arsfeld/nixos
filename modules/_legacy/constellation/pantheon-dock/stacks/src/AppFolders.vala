/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * Which folder of the Applications grid an app belongs in, from its desktop
 * entry alone. Hard-coded on purpose: see
 * docs/superpowers/specs/2026-10-31-dock-stacks-progress-design.md.
 */

namespace Dock.AppFolders {
    /* NONE is the top level; the rest are in the order the folder cells appear. */
    public enum Folder {
        NONE,
        GAMES,
        SYSTEM,
        UTILITIES,
        TERMINAL;

        public string title () {
            switch (this) {
                case GAMES: return _("Games");
                case SYSTEM: return _("System");
                case UTILITIES: return _("Utilities");
                case TERMINAL: return _("Terminal Tools");
                default: return "";
            }
        }
    }

    // Main categories that make a Utility app an everyday one (a calculator
    // stays in Utilities, a note-taking app tagged Utility;Office does not).
    private const string[] EVERYDAY_CATEGORIES = {
        "AudioVideo", "Audio", "Video", "Development", "Education",
        "Graphics", "Network", "Office", "Science"
    };

    /* categories is the raw `Categories` value; the first matching rule wins. */
    public Folder classify (string? categories, bool terminal) {
        if (terminal) {
            return TERMINAL;
        }
        var cats = (categories ?? "").split (";");
        if ("Game" in cats) {
            return GAMES;
        }
        if ("System" in cats || "Settings" in cats) {
            return SYSTEM;
        }
        if ("Utility" in cats) {
            foreach (unowned var everyday in EVERYDAY_CATEGORIES) {
                if (everyday in cats) {
                    return NONE;
                }
            }
            return UTILITIES;
        }
        return NONE;
    }

    public Folder classify_app (AppInfo app) {
        var desktop = app as DesktopAppInfo;
        if (desktop == null) {
            return NONE;
        }
        return classify (desktop.get_categories (), desktop.get_boolean ("Terminal"));
    }
}
