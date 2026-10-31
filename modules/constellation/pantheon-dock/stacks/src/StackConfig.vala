/*
 * SPDX-License-Identifier: GPL-3.0
 *
 * One entry of the io.elementary.dock `stacks` key, validated.
 */

namespace Dock {
    public errordomain StackConfigError {
        INVALID
    }
}

public class Dock.StackConfig : Object {
    public enum View { FAN, GRID }
    public enum Sort { DATE_ADDED, NAME }
    public enum Display { STACK, FOLDER }

    public const string APPLICATIONS = "applications";

    /* An absolute path, or APPLICATIONS. */
    public string source { get; construct; }
    public View view { get; construct; }
    public Sort sort { get; construct; }
    public Display display { get; construct; }

    public bool is_applications { get { return source == APPLICATIONS; } }

    public StackConfig (string source, View view, Sort sort, Display display) {
        Object (source: source, view: view, sort: sort, display: display);
    }

    public static StackConfig parse (string source, string view, string sort, string display) throws StackConfigError {
        string resolved;
        if (source == APPLICATIONS || Path.is_absolute (source)) {
            resolved = source;
        } else if (source.has_prefix ("~/")) {
            resolved = Path.build_filename (Environment.get_home_dir (), source.substring (2));
        } else {
            throw new StackConfigError.INVALID ("source must be an absolute path, ~/…, or '%s'", APPLICATIONS);
        }

        View parsed_view;
        switch (view) {
            case "fan": parsed_view = FAN; break;
            case "grid": parsed_view = GRID; break;
            default: throw new StackConfigError.INVALID ("unknown view '%s'", view);
        }

        Sort parsed_sort;
        switch (sort) {
            case "date-added": parsed_sort = DATE_ADDED; break;
            case "name": parsed_sort = NAME; break;
            default: throw new StackConfigError.INVALID ("unknown sort '%s'", sort);
        }

        Display parsed_display;
        switch (display) {
            case "stack": parsed_display = STACK; break;
            case "folder": parsed_display = FOLDER; break;
            default: throw new StackConfigError.INVALID ("unknown display '%s'", display);
        }

        return new StackConfig (resolved, parsed_view, parsed_sort, parsed_display);
    }

    /* Parses an a(ssss) value, logging and skipping invalid entries. */
    public static GenericArray<StackConfig> parse_all (Variant stacks) {
        var result = new GenericArray<StackConfig> ();
        for (size_t i = 0; i < stacks.n_children (); i++) {
            var entry = stacks.get_child_value (i);
            var source = entry.get_child_value (0).get_string ();
            try {
                result.add (parse (
                    source,
                    entry.get_child_value (1).get_string (),
                    entry.get_child_value (2).get_string (),
                    entry.get_child_value (3).get_string ()
                ));
            } catch (StackConfigError e) {
                warning ("Ignoring stack %s: %s", source, e.message);
            }
        }
        return result;
    }
}
