#include "ui_snapshot.h"

#if CONFIG_CLAUDE_BOARD_SNAPSHOT

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "mbedtls/base64.h"

typedef struct {
    int seq, w, h;
    char tag[16];
    unsigned char *b64;
    size_t n;
} snap_t;

static QueueHandle_t s_queue;

// Prints from a low-priority task with no locks held: serial output is slow, and doing it under
// the display lock stalls the UI, the watchdog and the network task.
static void print_task(void *arg)
{
    (void)arg;
    snap_t *s;
    for (;;) {
        if (xQueueReceive(s_queue, &s, portMAX_DELAY) != pdTRUE) continue;
        printf("SNAPSTART %d %d %d %s\n", s->seq, s->w, s->h, s->tag);
        for (size_t i = 0; i < s->n; i += 3000) {
            printf("SNAPDATA %.*s\n", (int)(s->n - i < 3000 ? s->n - i : 3000), s->b64 + i);
            vTaskDelay(pdMS_TO_TICKS(3));
        }
        printf("SNAPEND %d\n", s->seq);
        free(s->b64);
        free(s);
    }
}

// 466x466 RGB565 halved to 233x233 (nearest), base64 in lines:
//   SNAPSTART <seq> <w> <h> <tag> / SNAPDATA <chunk> ... / SNAPEND <seq>
// Consecutive identical frames are skipped; frames are dropped only when 8 are already waiting.
void ui_snapshot_log(lv_obj_t *screen, const char *tag)
{
    static int seq;
    static uint32_t last_hash;
    if (!s_queue) {
        s_queue = xQueueCreate(8, sizeof(snap_t *));
        xTaskCreate(print_task, "snap", 4096, NULL, 1, NULL);
    }
    if (uxQueueSpacesAvailable(s_queue) == 0) return;
    lv_draw_buf_t *snap = lv_snapshot_take(screen, LV_COLOR_FORMAT_RGB565);
    if (!snap) return;
    const int w = (int)snap->header.w / 2, h = (int)snap->header.h / 2;
    const uint32_t stride = snap->header.stride;
    uint16_t *small = malloc((size_t)w * h * 2);
    size_t cap = ((size_t)w * h * 2 / 3 + 4) * 4 + 8, n = 0;
    snap_t *s = calloc(1, sizeof *s);
    unsigned char *b64 = malloc(cap);
    bool ok = small && b64 && s;
    if (ok) {
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                small[y * w + x] = *(const uint16_t *)((const uint8_t *)snap->data + (size_t)(y * 2) * stride + (size_t)(x * 2) * 2);
        uint32_t hash = 2166136261u; // FNV-1a over the frame
        for (const uint8_t *p = (const uint8_t *)small, *e = p + (size_t)w * h * 2; p < e; p++) hash = (hash ^ *p) * 16777619u;
        if (hash == last_hash) ok = false;
        last_hash = hash;
        if (ok) ok = mbedtls_base64_encode(b64, cap, &n, (const unsigned char *)small, (size_t)w * h * 2) == 0;
    }
    if (ok) {
        s->seq = ++seq;
        s->w = w;
        s->h = h;
        strlcpy(s->tag, tag, sizeof s->tag);
        s->b64 = b64;
        s->n = n;
        if (xQueueSend(s_queue, &s, 0) != pdTRUE) ok = false;
    }
    if (!ok) {
        free(b64);
        free(s);
    }
    free(small);
    lv_draw_buf_destroy(snap);
}

#endif
