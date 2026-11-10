//! Paints one frame into the board's persistent framebuffer. It uses Slint's whole-buffer `render`, never
//! `render_by_line`: in Slint 1.18 the line-by-line renderer silently skips every `Path` ("Path rendering is not
//! supported in line-by-line mode"), so the rim's arcs, the command arcs and their icons, and the volume, purge and
//! link ticks and arcs would never reach the panel, while the host previews (which render whole buffers) look
//! right. With a reused buffer `render` repaints only what changed, as `render_by_line` did.

use slint::platform::software_renderer::{Rgb565Pixel, SoftwareRenderer};

/// Repaint what Slint marked dirty into `px` (`width` pixels a row, `height` rows) and return the rows to push to
/// the panel, `y0..y1`, widened to an even start and end as the panel requires. `None` when nothing changed.
pub fn paint(renderer: &SoftwareRenderer, px: &mut [Rgb565Pixel], width: usize, height: usize) -> Option<(usize, usize)> {
    let region = renderer.render(px, width);
    let size = region.bounding_box_size();
    if size.width == 0 || size.height == 0 {
        return None;
    }
    let y0 = (region.bounding_box_origin().y.max(0) as usize).min(height);
    let y1 = (y0 + size.height as usize).min(height);
    Some((y0 & !1, ((y1 + 1) & !1).min(height)))
}
