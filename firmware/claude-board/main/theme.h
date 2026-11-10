// Colours and sizes shared by the screens. State colours are fixed by the design spec.
#pragma once

#include "board_proto.h"

#define COL_WORKING 0x3b82f6 // blue
#define COL_WAITING 0xf59e0b // amber
#define COL_IDLE 0x6b7280    // grey
#define COL_DONE 0x22c55e    // green
#define COL_ERROR 0xef4444   // red

#define COL_BG 0x000000
#define COL_CARD 0x111827
#define COL_CARD_PRESSED 0x1f2937
#define COL_TEXT 0xf9fafb
#define COL_MUTED 0x9ca3af
#define COL_FAINT 0x1f2937

static inline unsigned state_colour(bp_state_t s)
{
    switch (s) {
    case ST_WORKING: return COL_WORKING;
    case ST_WAITING: return COL_WAITING;
    case ST_DONE: return COL_DONE;
    case ST_ERROR: return COL_ERROR;
    default: return COL_IDLE;
    }
}

static inline const char *state_name(bp_state_t s)
{
    switch (s) {
    case ST_WORKING: return "working";
    case ST_WAITING: return "waiting";
    case ST_DONE: return "done";
    case ST_ERROR: return "error";
    default: return "idle";
    }
}

#define AWAKE_MS 30000
#define BRIGHT_AWAKE 70
#define BRIGHT_IDLE 8
