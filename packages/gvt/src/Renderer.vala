/*
 * Renderer: draws the Engine's render state with GtkSnapshot and Pango.
 *
 * Each row is drawn into its own render node and kept, keyed by libghostty's
 * row id, until the row is dirty or the font or colors change; a frame
 * re-uses every clean row and only rebuilds the rest. The cursor is drawn on
 * top each frame and never cached.
 *
 * Text is laid out one Pango.Layout per run of single-cell ASCII cells with
 * the same style, with letter spacing that makes the font's advance exactly
 * one cell. Anything else (wide characters, combining sequences, non-ASCII)
 * is laid out alone at its own column, so a glyph from a fallback font can
 * never push the cells after it off the grid.
 */
namespace Gvt {
    internal class Renderer : Object {
        private const string DEFAULT_FONT = "Monospace 10";

        private unowned Terminal owner;

        /* Indexed by CellFlag BOLD | ITALIC (0-3). */
        private Pango.FontDescription[] fonts = new Pango.FontDescription[4];
        private int cell_w = 1;
        private int cell_h = 1;
        private int ascent = 0;
        private int letter_spacing = 0;

        /* Bumped by anything that changes how every row looks. */
        private uint generation = 1;
        private uint cache_generation = 0;
        private HashTable<string, CachedRow> cache = new HashTable<string, CachedRow> (str_hash, str_equal);

        /* Applied to the default background only, as VTE does. */
        internal double background_alpha = 1.0;
        internal Gdk.RGBA selection_color = { 0.21f, 0.52f, 0.89f, 1.0f };

        /* Frames drawn; tests count redraws with it. */
        internal uint frames = 0;

        /* The text under the cursor, found while walking the rows. */
        private string? cursor_text = null;
        private bool cursor_wide = false;

        private class CachedRow {
            public Gsk.RenderNode? node;

            public CachedRow (owned Gsk.RenderNode? node) {
                this.node = (owned) node;
            }
        }

        public Renderer (Terminal owner) {
            this.owner = owner;
            set_font (Pango.FontDescription.from_string (DEFAULT_FONT));
        }

        /* `font` is already scaled by the terminal's font_scale. */
        public void set_font (Pango.FontDescription font) {
            for (var i = 0; i < 4; i++) {
                fonts[i] = font.copy ();
                fonts[i].set_weight ((i & CellFlag.BOLD) != 0 ? Pango.Weight.BOLD : Pango.Weight.NORMAL);
                fonts[i].set_style ((i & CellFlag.ITALIC) != 0 ? Pango.Style.ITALIC : Pango.Style.NORMAL);
            }
            measure ();
            invalidate ();
        }

        /* Forgets every cached row. */
        public void invalidate () {
            generation++;
        }

        public void cell_size (out int w, out int h) {
            w = cell_w;
            h = cell_h;
        }

        private void measure () {
            var context = owner.get_pango_context ();
            var metrics = context.get_metrics (fonts[0], null);
            var asc = metrics.get_ascent ();
            var desc = metrics.get_descent ();
            ascent = ceil_pixels (asc);
            cell_h = int.max (1, ceil_pixels (asc + desc));

            // The real advance, which Pango may not round to whole pixels.
            var layout = new Pango.Layout (context);
            layout.set_font_description (fonts[0]);
            layout.set_text ("MMMMMMMMMM", -1);
            int w, h;
            layout.get_size (out w, out h);
            var advance = w / 10;
            cell_w = int.max (1, ceil_pixels (advance));
            letter_spacing = cell_w * Pango.SCALE - advance;
        }

        private static int ceil_pixels (int units) {
            return (units + Pango.SCALE - 1) / Pango.SCALE;
        }

        public void snapshot (Gtk.Snapshot s, int width, int height) {
            frames++;
            unowned Engine engine = owner.engine;
            RenderDirty dirty;
            if (!engine.render_begin (out dirty)) {
                return;
            }
            uint32 fg, bg, cursor_rgb;
            bool has_cursor_color;
            engine.render_colors (out fg, out bg, out has_cursor_color, out cursor_rgb);
            s.append_color (rgba (bg, background_alpha), { { 0, 0 }, { width, height } });

            uint16 cx, cy;
            RenderCursor cursor_style;
            var has_cursor = engine.render_cursor (out cx, out cy, out cursor_style);
            cursor_text = null;
            cursor_wide = false;

            var rebuild_all = dirty == RenderDirty.FULL || generation != cache_generation;
            var next = new HashTable<string, CachedRow> (str_hash, str_equal);
            if (engine.rows_begin ()) {
                int y;
                while (engine.rows_next (out y)) {
                    var key = engine.row_key ();
                    CachedRow? row = null;
                    if (!rebuild_all && !engine.row_dirty ()) {
                        row = cache.lookup (key);
                    }
                    if (row == null) {
                        row = new CachedRow (build_row (engine, fg, bg));
                    }
                    next.insert (key, row);
                    if (row.node != null) {
                        var at = new Gsk.Transform ().translate ({ 0, y * cell_h });
                        s.append_node (new Gsk.TransformNode (row.node, at));
                    }
                    if (has_cursor && y == cy) {
                        read_cursor_cell (engine, cx);
                    }
                }
            }
            cache = next;
            cache_generation = generation;

            if (has_cursor) {
                draw_cursor (s, cx, cy, cursor_style, has_cursor_color ? cursor_rgb : fg, bg);
            }
            engine.render_clean ();
        }

        private void read_cursor_cell (Engine engine, uint16 cx) {
            if (engine.row_cells () && engine.cells_select (cx)) {
                cursor_text = engine.cell_text ();
                cursor_wide = engine.cell_width () == CellWidth.WIDE;
            }
        }

        /* One row at y = 0: merged background rects, then text runs. */
        private Gsk.RenderNode? build_row (Engine engine, uint32 default_fg, uint32 default_bg) {
            var s = new Gtk.Snapshot ();
            uint16 sel_start, sel_end;
            var has_selection = engine.row_selection (out sel_start, out sel_end);
            if (!engine.row_cells ()) {
                return null;
            }

            // The pending background run: [bg_start, x) in bg_color.
            int bg_start = -1;
            Gdk.RGBA bg_color = {};
            // The pending text run, starting at column text_start.
            var text = new StringBuilder ();
            int text_start = -1;
            int text_end = -1;
            Gdk.RGBA text_color = {};
            uint16 text_flags = 0;

            int x = 0;
            for (; engine.cells_next (); x++) {
                var flags = engine.cell_flags ();
                uint32 fg, bg;
                var has_fg = engine.cell_foreground (out fg);
                var has_bg = engine.cell_background (out bg);
                if (!has_fg) {
                    fg = default_fg;
                }
                if ((flags & CellFlag.INVERSE) != 0) {
                    var swap = has_bg ? bg : default_bg;
                    bg = fg;
                    fg = swap;
                    has_bg = true;
                }

                Gdk.RGBA? cell_bg = null;
                if (has_selection && x >= sel_start && x <= sel_end) {
                    cell_bg = selection_color;
                } else if (has_bg) {
                    cell_bg = rgba (bg);
                }
                if (bg_start >= 0 && (cell_bg == null || !cell_bg.equal (bg_color))) {
                    fill_cells (s, bg_start, x, bg_color);
                    bg_start = -1;
                }
                if (cell_bg != null && bg_start < 0) {
                    bg_start = x;
                    bg_color = cell_bg;
                }

                var width = engine.cell_width ();
                var glyph = width == CellWidth.SPACER || (flags & CellFlag.INVISIBLE) != 0
                    ? null : engine.cell_text ();
                if (glyph == null || glyph == " ") {
                    continue;
                }
                var color = rgba (fg, (flags & CellFlag.FAINT) != 0 ? 0.5 : 1.0);
                var simple = width == CellWidth.NARROW && glyph.length == 1 && glyph[0] < 0x80;
                var extends = text_start >= 0 && text_end == x && text_flags == flags
                    && text_color.equal (color);
                if (simple && extends) {
                    text.append (glyph);
                    text_end = x + 1;
                    continue;
                }
                if (text_start >= 0) {
                    draw_text (s, text.str, text_start, text_color, text_flags);
                    text_start = -1;
                }
                if (simple) {
                    text.truncate ();
                    text.append (glyph);
                    text_start = x;
                    text_end = x + 1;
                    text_color = color;
                    text_flags = flags;
                } else {
                    draw_text (s, glyph, x, color, flags);
                }
            }
            if (bg_start >= 0) {
                fill_cells (s, bg_start, x, bg_color);
            }
            if (text_start >= 0) {
                draw_text (s, text.str, text_start, text_color, text_flags);
            }
            return s.to_node ();
        }

        private void fill_cells (Gtk.Snapshot s, int from, int to, Gdk.RGBA color) {
            s.append_color (color, { { from * cell_w, 0 }, { (to - from) * cell_w, cell_h } });
        }

        /* Draws text with its first cell at column col of a row at y = 0. */
        private void draw_text (Gtk.Snapshot s, string text, int col, Gdk.RGBA color, uint16 flags) {
            var layout = owner.create_pango_layout (text);
            layout.set_font_description (fonts[flags & (CellFlag.BOLD | CellFlag.ITALIC)]);
            var attrs = new Pango.AttrList ();
            attrs.insert (Pango.attr_letter_spacing_new (letter_spacing));
            if ((flags & CellFlag.UNDERLINE) != 0) {
                attrs.insert (Pango.attr_underline_new (Pango.Underline.SINGLE));
            }
            if ((flags & CellFlag.STRIKETHROUGH) != 0) {
                attrs.insert (Pango.attr_strikethrough_new (true));
            }
            if ((flags & CellFlag.OVERLINE) != 0) {
                attrs.insert (Pango.attr_overline_new (Pango.Overline.SINGLE));
            }
            layout.set_attributes (attrs);
            var baseline = layout.get_baseline () / Pango.SCALE;
            s.save ();
            s.translate ({ col * cell_w, ascent - baseline });
            s.append_layout (layout, color);
            s.restore ();
        }

        private void draw_cursor (Gtk.Snapshot s, uint16 cx, uint16 cy, RenderCursor style,
                                  uint32 cursor_rgb, uint32 bg) {
            var color = rgba (cursor_rgb);
            var x = cx * cell_w;
            var y = cy * cell_h;
            var w = cursor_wide ? 2 * cell_w : cell_w;
            var thickness = int.max (1, cell_h / 10);
            // Without focus, a block is drawn hollow, as VTE does.
            if (style == RenderCursor.BLOCK && !owner.has_focus) {
                style = RenderCursor.BLOCK_HOLLOW;
            }
            switch (style) {
            case RenderCursor.BAR:
                s.append_color (color, { { x, y }, { thickness, cell_h } });
                break;
            case RenderCursor.UNDERLINE:
                s.append_color (color, { { x, y + cell_h - thickness }, { w, thickness } });
                break;
            case RenderCursor.BLOCK_HOLLOW:
                var outline = Gsk.RoundedRect ();
                outline.init_from_rect ({ { x, y }, { w, cell_h } }, 0);
                float[] widths = { 1, 1, 1, 1 };
                Gdk.RGBA[] colors = { color, color, color, color };
                s.append_border (outline, widths, colors);
                break;
            default:
                s.append_color (color, { { x, y }, { w, cell_h } });
                if (cursor_text != null) {
                    s.save ();
                    s.translate ({ 0, y });
                    draw_text (s, cursor_text, cx, rgba (bg), 0);
                    s.restore ();
                }
                break;
            }
        }

        private static Gdk.RGBA rgba (uint32 rgb, double alpha = 1.0) {
            return {
                       ((rgb >> 16) & 0xff) / 255.0f,
                       ((rgb >> 8) & 0xff) / 255.0f,
                       (rgb & 0xff) / 255.0f,
                       (float) alpha
            };
        }
    }
}
