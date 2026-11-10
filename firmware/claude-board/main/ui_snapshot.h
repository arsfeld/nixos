// Debug only (CONFIG_CLAUDE_BOARD_SNAPSHOT): log a downscaled screenshot over serial, so the screens
// can be inspected without looking at the board. Compiles to nothing otherwise.
#pragma once

#include "lvgl.h"

#if CONFIG_CLAUDE_BOARD_SNAPSHOT
void ui_snapshot_log(lv_obj_t *screen, const char *tag);
#else
static inline void ui_snapshot_log(lv_obj_t *screen, const char *tag)
{
    (void)screen;
    (void)tag;
}
#endif
