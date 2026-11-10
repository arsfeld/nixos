#include "chime.h"

#include <math.h>
#include <stdint.h>

#include "bsp/esp-bsp.h"
#include "esp_codec_dev.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

static const char *TAG = "chime";

#define RATE 16000
#define NOTE_MS 110
#define MIN_GAP_US (3 * 1000000LL)

static esp_codec_dev_handle_t s_speaker;
static SemaphoreHandle_t s_wake;
static int64_t s_last_us;

static void tone(int16_t *out, int n, float hz)
{
    for (int i = 0; i < n; i++) {
        float env = 1.0f;
        if (i < 200) env = i / 200.0f;                 // fade in: no click
        if (i > n - 400) env = (n - i) / 400.0f;       // fade out
        out[i] = (int16_t)(sinf(2.0f * (float)M_PI * hz * (float)i / RATE) * 9000.0f * env);
    }
}

static void chime_task(void *arg)
{
    (void)arg;
    const int n = RATE * NOTE_MS / 1000;
    int16_t *buf = malloc((size_t)n * 2 * sizeof *buf);
    if (!buf) vTaskDelete(NULL);
    tone(buf, n, 880.0f);
    tone(buf + n, n, 1175.0f);
    esp_codec_dev_sample_info_t fs = {.sample_rate = RATE, .channel = 1, .bits_per_sample = 16};
    for (;;) {
        xSemaphoreTake(s_wake, portMAX_DELAY);
        if (esp_codec_dev_open(s_speaker, &fs) != ESP_CODEC_DEV_OK) {
            ESP_LOGW(TAG, "speaker open failed");
            continue;
        }
        esp_codec_dev_set_out_vol(s_speaker, 55);
        esp_codec_dev_write(s_speaker, buf, n * 2 * (int)sizeof *buf);
        esp_codec_dev_close(s_speaker); // silent, and no idle hiss between chimes
    }
}

void chime_init(void)
{
    s_speaker = bsp_audio_codec_speaker_init();
    if (!s_speaker) {
        ESP_LOGW(TAG, "no speaker: chimes disabled");
        return;
    }
    s_wake = xSemaphoreCreateBinary();
    xTaskCreate(chime_task, "chime", 4096, NULL, 3, NULL);
}

void chime_play(void)
{
    if (!s_speaker) return;
    int64_t now = esp_timer_get_time();
    if (now - s_last_us < MIN_GAP_US) return;
    s_last_us = now;
    xSemaphoreGive(s_wake);
}
