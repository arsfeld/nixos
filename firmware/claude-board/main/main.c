// claude-board firmware: shows the state of every Claude Code session and answers Claude's
// questions. Design: docs/superpowers/specs/2026-11-09-claude-board-design.md

#include "board_proto.h"
#include "bsp/esp-bsp.h"
#include "chime.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "net.h"
#include "ui.h"

static const char *TAG = "claude-board";

static bp_model_t *s_model;
static SemaphoreHandle_t s_model_lock;

// Runs in the networking task.
static void on_message(const char *json, size_t len)
{
    xSemaphoreTake(s_model_lock, portMAX_DELAY);
    int rc = bp_apply(s_model, json, len);
    xSemaphoreGive(s_model_lock);
    if (rc == BP_ERR) ESP_LOGW(TAG, "ignored a malformed message (%d bytes)", (int)len);
    ui_model_changed(); // takes the display lock, never while the model lock is held
}

static void on_status(bool connected)
{
    ESP_LOGI(TAG, "bridge %s", connected ? "connected" : "disconnected");
    ui_set_link(connected);
}

// Internal RAM is the scarce resource (see sdkconfig.defaults); a line every 30 s shows a leak or
// a squeeze long before something fails to allocate.
static void heap_report(void *arg)
{
    (void)arg;
    for (;;) {
        ESP_LOGI(TAG, "heap: internal free=%u largest=%u dma_largest=%u psram free=%u",
                 (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                 (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
                 (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL),
                 (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
        vTaskDelay(pdMS_TO_TICKS(30000));
    }
}

void app_main(void)
{
    s_model = bp_model_new();
    s_model_lock = xSemaphoreCreateMutex();

    bsp_display_start();
    ui_init(s_model, s_model_lock);
    chime_init();
    ESP_LOGI(TAG, "display and touch up; starting network");
    net_start(on_message, on_status);
    xTaskCreate(heap_report, "heap", 3072, NULL, 1, NULL);
}
