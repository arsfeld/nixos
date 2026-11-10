// claude-board firmware. Task 10 stage: the hello screen plus networking; incoming messages are
// applied to the protocol model and summarised in the log. The real screens come in Task 11.

#include "board_proto.h"
#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "lvgl.h"
#include "net.h"

static const char *TAG = "claude-board";

static lv_obj_t *coords;
static lv_obj_t *link_label;

static bp_model_t *s_model;
static SemaphoreHandle_t s_model_lock;

static void on_touch(lv_event_t *e)
{
    (void)e;
    lv_point_t p;
    lv_indev_get_point(lv_indev_active(), &p);
    ESP_LOGI(TAG, "touch %d,%d", (int)p.x, (int)p.y);
    lv_label_set_text_fmt(coords, "%d, %d", (int)p.x, (int)p.y);
}

static void on_message(const char *json, size_t len)
{
    xSemaphoreTake(s_model_lock, portMAX_DELAY);
    int rc = bp_apply(s_model, json, len);
    const bp_session_t *s;
    size_t n = bp_sessions(s_model, &s);
    ESP_LOGI(TAG, "message (%d bytes) rc=%d: %u sessions, %u waiting, %u questions", (int)len, rc, (unsigned)n,
             (unsigned)bp_waiting_count(s_model), (unsigned)bp_ask_count(s_model));
    for (size_t i = 0; i < n && i < 5; i++)
        ESP_LOGI(TAG, "  %s/%s state=%d since=%lld", s[i].host, s[i].project, (int)s[i].state, (long long)s[i].since);
    xSemaphoreGive(s_model_lock);
}

static void on_status(bool connected)
{
    bsp_display_lock(-1);
    lv_label_set_text(link_label, connected ? "bridge: online" : "bridge: offline");
    lv_obj_set_style_text_color(link_label, lv_color_hex(connected ? 0x22c55e : 0xef4444), 0);
    bsp_display_unlock();
}

void app_main(void)
{
    s_model = bp_model_new();
    s_model_lock = xSemaphoreCreateMutex();

    bsp_display_start();
    bsp_display_lock(-1);

    lv_obj_t *scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, lv_color_black(), 0);

    lv_obj_t *title = lv_label_create(scr);
    lv_label_set_text(title, "claude board");
    lv_obj_set_style_text_color(title, lv_color_white(), 0);
    lv_obj_set_style_text_font(title, &lv_font_montserrat_28, 0);
    lv_obj_align(title, LV_ALIGN_CENTER, 0, -60);

    // working blue, waiting amber, idle grey, done green, error red
    const uint32_t colours[] = {0x3b82f6, 0xf59e0b, 0x6b7280, 0x22c55e, 0xef4444};
    for (int i = 0; i < 5; i++) {
        lv_obj_t *dot = lv_obj_create(scr);
        lv_obj_set_size(dot, 40, 40);
        lv_obj_set_style_radius(dot, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(dot, lv_color_hex(colours[i]), 0);
        lv_obj_set_style_border_width(dot, 0, 0);
        lv_obj_align(dot, LV_ALIGN_CENTER, (i - 2) * 56, 0);
    }

    link_label = lv_label_create(scr);
    lv_label_set_text(link_label, "bridge: offline");
    lv_obj_set_style_text_color(link_label, lv_color_hex(0xef4444), 0);
    lv_obj_set_style_text_font(link_label, &lv_font_montserrat_20, 0);
    lv_obj_align(link_label, LV_ALIGN_CENTER, 0, 60);

    coords = lv_label_create(scr);
    lv_label_set_text(coords, "touch me");
    lv_obj_set_style_text_color(coords, lv_color_hex(0x9ca3af), 0);
    lv_obj_set_style_text_font(coords, &lv_font_montserrat_16, 0);
    lv_obj_align(coords, LV_ALIGN_CENTER, 0, 100);

    lv_obj_add_event_cb(scr, on_touch, LV_EVENT_PRESSING, NULL);
    bsp_display_unlock();
    ESP_LOGI(TAG, "display and touch up; starting network");

    net_start(on_message, on_status);
}
