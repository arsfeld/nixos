// ui: the board's screens (idle, session list, question, session detail) over LVGL.
//
// Lock order is display, then model: every function here takes the display lock itself (callers
// must NOT hold it) and then the model lock while reading the model.
#pragma once

#include <stdbool.h>

#include "board_proto.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

// Build the UI. The display (bsp_display_start) must already be running.
void ui_init(bp_model_t *model, SemaphoreHandle_t model_lock);

// The model changed (any task, no locks held): wake the screen, redraw, chime if something now
// needs the user.
void ui_model_changed(void);

// The bridge connection came up or went down.
void ui_set_link(bool connected);
