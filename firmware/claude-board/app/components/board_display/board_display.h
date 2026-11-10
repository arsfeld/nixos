// board_display: the Waveshare ESP32-S3-Touch-AMOLED-1.75's panel, touch and speaker, without LVGL.
// Plain C so Rust can bind it. The panel needs update windows with an even origin and an even size.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int16_t x, y;
    bool pressed;
} bd_touch_t;

// Panel, touch, brightness and speaker.
esp_err_t bd_init(void);
// Queue RGB565 pixels (bytes in wire order) for the window [x0,x1) x [y0,y1) and return once queued.
// x0, y0, x1 and y1 must be even, the window at most 16 full-width rows, and the buffer in DMA-capable
// internal RAM. The buffer must stay unchanged until the next bd_draw call has returned or bd_wait has.
esp_err_t bd_draw(int x0, int y0, int x1, int y1, const uint16_t *rgb565);
// Block until every queued bd_draw has been sent.
esp_err_t bd_wait(void);
// Latest touch state. False when the touch controller could not be read.
bool bd_touch_read(bd_touch_t *out);
void bd_set_brightness(uint8_t percent);
// Non-blocking two-tone chime, ignored if one played in the last few seconds.
void bd_chime(void);

#ifdef __cplusplus
}
#endif
