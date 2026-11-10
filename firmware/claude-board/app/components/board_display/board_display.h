// board_display: the Waveshare ESP32-S3-Touch-AMOLED-1.75's panel, touch and speaker, without LVGL.
// Plain C so Rust can bind it. The panel needs update windows with an even origin and an even size.
#pragma once

#include <stdbool.h>
#include <stddef.h>
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
// The same chime without the rate limit, to hear a new volume (does nothing while the mic or a reply has the clock).
void bd_chime_now(void);
// Speaker volume for the chime and replies, 0 to 100 on the codec's scale; a reply playing follows at once.
void bd_set_volume(uint8_t percent);
// Microphone (16-bit mono). Capture and the chime share one I2S clock and never overlap: bd_chime does nothing
// while the microphone is open, and bd_mic_open waits for a chime in progress.
// Open at rate_hz (16000 for the uplink); ESP_ERR_INVALID_STATE if already open, ESP_ERR_NOT_SUPPORTED if absent.
esp_err_t bd_mic_open(uint32_t rate_hz);
// Read exactly max_samples mono samples (blocks about max_samples / rate). Negative on error or timeout.
int bd_mic_read(int16_t *out, int max_samples, uint32_t timeout_ms);
void bd_mic_close(void);
// Spoken replies (16-bit mono PCM). While a stream is open (begin .. end) bd_chime does nothing and bd_mic_open fails
// with ESP_ERR_INVALID_STATE; bd_speaker_begin fails the same way while the microphone is open, and waits up to 1 s
// for a chime in progress. One thread should call all three.
esp_err_t bd_speaker_begin(uint32_t rate_hz);
// Blocking write of whole samples; returns the bytes written, negative on error or when no stream is open.
int bd_speaker_write(const void *pcm, size_t bytes);
// Drain and close, silently. Harmless when nothing is open.
void bd_speaker_end(void);

#ifdef __cplusplus
}
#endif
