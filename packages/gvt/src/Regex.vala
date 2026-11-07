/*
 * Regex: VTE's Vte.Regex, the pattern handed to search_set_regex () and
 * match_add_regex ().
 *
 * The flags are PCRE2 compile flags in VTE. Here a search pattern is always
 * a literal, matched without case (libghostty's search), so its flags are
 * ignored; a match pattern is a GLib.Regex compiled with MULTILINE, whatever
 * the flags say.
 */
namespace Gvt {
    public class Regex : Object {
        /* The literal needle of a search pattern; null for a match pattern. */
        internal string? literal = null;
        /* The compiled match pattern; null for a search pattern. */
        internal GLib.Regex? compiled = null;

        /* pattern_length is in bytes; -1 means up to the NUL. */
        public Regex.for_search (string pattern, ssize_t pattern_length, uint32 flags) throws Error {
            literal = slice (pattern, pattern_length);
        }

        /* Throws the GLib.RegexError of a pattern that does not compile. */
        public Regex.for_match (string pattern, ssize_t pattern_length, uint32 flags) throws Error {
            compiled = new GLib.Regex (slice (pattern, pattern_length), RegexCompileFlags.MULTILINE);
        }

        private static string slice (string pattern, ssize_t length) {
            if (length < 0 || length >= pattern.length) {
                return pattern;
            }
            return pattern.substring (0, (long) length);
        }
    }
}
