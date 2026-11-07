/*
 * Renderer: draws the Engine's render state with GtkSnapshot and Pango.
 *
 * Selected cells are drawn in reverse video (VTE's default).
 *
 * Each row is drawn into its own render node and kept, keyed by libghostty's
 * row id, until the row is dirty or the font or colors change; a frame
 * re-uses every clean row and only rebuilds the rest. The cursor is drawn on
 * top each frame and never cached.
 *
 * Text is laid out one Pango.Layout per run of adjacent narrow cells with
 * the same style, each holding one character (ASCII, accented letters, box
 * drawing alike), and then every cluster's advance is set to exactly its
 * cells, the glyphs centred in them, as VTE draws. No font is assumed to be
 * monospace: the configured one may resolve to a proportional face, and a
 * bold or fallback face may advance differently from the regular one the
 * cell was measured with. Wide characters and multi-codepoint graphemes
 * are laid out alone and centred in their own cells. Either way a glyph
 * from a fallback font can never push the cells after it off the grid.
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

        /* Bumped by anything that changes how every row looks. */
        private uint generation = 1;
        private uint cache_generation = 0;
        private HashTable<string, CachedRow> cache = new HashTable<string, CachedRow> (str_hash, str_equal);

        /* Applied to the default background only, as VTE does. */
        internal double background_alpha = 1.0;

        /* Frames drawn; tests count redraws with it. */
        internal uint frames = 0;
        /* Pango layouts made; tests count them per frame. */
        internal uint layouts = 0;

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
            cell_w = int.max (1, ceil_pixels (w / 10));
        }

        private static int ceil_pixels (int units) {
            return (units + Pango.SCALE - 1) / Pango.SCALE;
        }

        /* Pango units rounded down to whole pixels, so a centred glyph's
         * stems stay as sharp as at a cell's own (whole-pixel) origin. */
        private static int whole_pixels (int units) {
            return units / Pango.SCALE * Pango.SCALE;
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
            // Backgrounds go in s and text in ts, which is appended after
            // them: a text run can end (at a blank or a colour change)
            // before the background under it does, and a fill appended
            // later would paint over it.
            var s = new Gtk.Snapshot ();
            var ts = new Gtk.Snapshot ();
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
                // A selected cell is drawn in reverse video, as VTE draws
                // one when no highlight color is set: it follows the
                // palette and the theme's colors, whatever they are. Inverse
                // and selected cancel out.
                var selected = has_selection && x >= sel_start && x <= sel_end;
                if (((flags & CellFlag.INVERSE) != 0) != selected) {
                    var swap = has_bg ? bg : default_bg;
                    bg = fg;
                    fg = swap;
                    has_bg = true;
                }

                Gdk.RGBA? cell_bg = null;
                if (has_bg) {
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
                var simple = width == CellWidth.NARROW && glyph.char_count () == 1;
                var extends = text_start >= 0 && text_end == x && text_flags == flags
                    && text_color.equal (color);
                if (simple && extends) {
                    text.append (glyph);
                    text_end = x + 1;
                    continue;
                }
                if (text_start >= 0) {
                    draw_text (ts, text.str, text_start, text_end - text_start, text_color, text_flags, true);
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
                    draw_text (ts, glyph, x, width == CellWidth.WIDE ? 2 : 1, color, flags, false);
                }
            }
            if (bg_start >= 0) {
                fill_cells (s, bg_start, x, bg_color);
            }
            if (text_start >= 0) {
                draw_text (ts, text.str, text_start, text_end - text_start, text_color, text_flags, true);
            }
            var text_node = ts.to_node ();
            if (text_node != null) {
                s.append_node (text_node);
            }
            return s.to_node ();
        }

        private void fill_cells (Gtk.Snapshot s, int from, int to, Gdk.RGBA color) {
            s.append_color (color, { { from * cell_w, 0 }, { (to - from) * cell_w, cell_h } });
        }

        /* Draws text over `cells` cells from column col of a row at y = 0.
         * text is either a run (`run`), one character per cell, or a single
         * character or grapheme spanning all the cells. */
        private void draw_text (Gtk.Snapshot s, string text, int col, int cells,
                                Gdk.RGBA color, uint16 flags, bool run) {
            layouts++;
            var layout = owner.create_pango_layout (text);
            layout.set_font_description (fonts[flags & (CellFlag.BOLD | CellFlag.ITALIC)]);
            var attrs = new Pango.AttrList ();
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
            var shift = 0;
            if (run) {
                fit_to_cells (layout, text);
            } else {
                int w, h;
                layout.get_size (out w, out h);
                shift = whole_pixels ((cells * cell_w * Pango.SCALE - w) / 2);
            }
            var baseline = layout.get_baseline () / Pango.SCALE;
            s.save ();
            s.translate ({ col * cell_w + (float) shift / Pango.SCALE, ascent - baseline });
            s.append_layout (layout, color);
            s.restore ();
        }

        /* Gives each cluster of a one-character-per-cell layout an advance
         * of exactly its cells (its characters), its glyphs centred in them, so every cluster
         * starts at its own column whatever the font's advances are. Edits
         * the line's glyphs in place, which get_line (unlike its _readonly
         * twin) permits. */
        private void fit_to_cells (Pango.Layout layout, string text) {
            unowned Pango.LayoutLine? line = layout.get_line (0);
            if (line == null) {
                return;
            }
            foreach (unowned Pango.LayoutRun run in line.runs) {
                unowned Pango.GlyphString glyphs = run.glyphs;
                var iter = Pango.GlyphItemIter ();
                for (var more = iter.init_start (run, text); more; more = iter.next_cluster ()) {
                    // end_glyph is exclusive, and before start_glyph in RTL.
                    var first = int.min (iter.start_glyph, iter.end_glyph + 1);
                    var last = int.max (iter.start_glyph, iter.end_glyph - 1);
                    if (first > last) {
                        continue;
                    }
                    var natural = 0;
                    for (var i = first; i <= last; i++) {
                        natural += glyphs.glyphs[i].geometry.width;
                    }
                    var cells = (int) text.offset (iter.start_index).char_count (iter.end_index - iter.start_index);
                    var delta = cells * cell_w * Pango.SCALE - natural;
                    var centre = whole_pixels (delta / 2);
                    for (var i = first; i <= last; i++) {
                        glyphs.glyphs[i].geometry.x_offset += centre;
                    }
                    glyphs.glyphs[last].geometry.width += delta;
                }
            }
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
                    draw_text (s, cursor_text, cx, cursor_wide ? 2 : 1, rgba (bg), 0, false);
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
