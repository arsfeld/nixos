// Task 8 hello world: proves the toolchain, the display and the touch panel. Draws the five
// session-state colours on a black screen and prints touch coordinates to the log.

#include "bsp/esp-bsp.h"
#include "esp_log.h"
#include "lvgl.h"

static const char *TAG = "claude-board";

static lv_obj_t *coords;

static void on_touch(lv_event_t *e)
{
    (void)e;
    lv_point_t p;
    lv_indev_get_point(lv_indev_active(), &p);
    ESP_LOGI(TAG, "touch %d,%d", (int)p.x, (int)p.y);
    lv_label_set_text_fmt(coords, "%d, %d", (int)p.x, (int)p.y);
}

void app_main(void)
{
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

    coords = lv_label_create(scr);
    lv_label_set_text(coords, "touch me");
    lv_obj_set_style_text_color(coords, lv_color_hex(0x9ca3af), 0);
    lv_obj_set_style_text_font(coords, &lv_font_montserrat_20, 0);
    lv_obj_align(coords, LV_ALIGN_CENTER, 0, 70);

    lv_obj_add_event_cb(scr, on_touch, LV_EVENT_PRESSING, NULL);
    bsp_display_unlock();
    ESP_LOGI(TAG, "hello: display and touch up");
}
