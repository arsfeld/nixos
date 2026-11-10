#include "ui.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

#include "bsp/esp-bsp.h"
#include "chime.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "lvgl.h"
#include "net.h"
#include "theme.h"
#include "ui_snapshot.h"

static const char *TAG = "ui";

typedef enum { PAGE_IDLE, PAGE_LIST, PAGE_QUESTION, PAGE_DETAIL } page_t;

#define MAX_ROWS 32
#define MAX_OPTIONS 4

static bp_model_t *s_model;
static SemaphoreHandle_t s_lock;
static lv_obj_t *s_screen;
static lv_obj_t *s_content;
static lv_obj_t *s_list;
static page_t s_page = PAGE_IDLE;
static bool s_link;
static int64_t s_last_change_ms;
static size_t s_prev_waiting;
static char s_prev_ask_id[BP_ID_MAX];
static char s_detail_host[BP_HOST_MAX], s_detail_session[BP_SESSION_MAX];

// Multi-select state for the question on screen.
static bool s_sel[MAX_OPTIONS];
static char s_sel_ask[BP_ID_MAX];
static size_t s_sel_q;

// The session cards currently shown, so their "time in state" can tick without a rebuild.
static struct {
    lv_obj_t *sub;
} s_rows[MAX_ROWS];
static size_t s_nrows;

// ---- helpers --------------------------------------------------------------------------------

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static bool awake(void)
{
    return lv_display_get_inactive_time(NULL) < AWAKE_MS || now_ms() - s_last_change_ms < AWAKE_MS;
}

static void fmt_ago(char *buf, size_t n, int64_t since)
{
    time_t now = time(NULL);
    if (now < 1735689600) { // the clock is not set yet
        snprintf(buf, n, "--");
        return;
    }
    int64_t d = now - since;
    if (d < 0) d = 0;
    if (d < 60) snprintf(buf, n, "%llds", (long long)d);
    else if (d < 3600) snprintf(buf, n, "%lldm", (long long)(d / 60));
    else if (d < 86400) snprintf(buf, n, "%lldh", (long long)(d / 3600));
    else snprintf(buf, n, "%lldd", (long long)(d / 86400));
}

static lv_obj_t *mk_label(lv_obj_t *parent, const char *text, const lv_font_t *font, unsigned colour)
{
    lv_obj_t *l = lv_label_create(parent);
    lv_label_set_text(l, text);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(colour), 0);
    return l;
}

// Copy at most `max_bytes` of `s`, never ending mid-character, with an ellipsis if cut.
static void fit_copy(char *dst, size_t cap, const char *s, size_t max_bytes)
{
    size_t n = bp_fit(s, max_bytes < cap - 4 ? max_bytes : cap - 4);
    memcpy(dst, s, n);
    if (s[n]) memcpy(dst + n, "...", 4);
    else dst[n] = 0;
}

#if CONFIG_CLAUDE_BOARD_SELFTEST
// Debug only: the buttons of the current page, so tick() can click them like a finger would.
static lv_obj_t *t_opt[MAX_OPTIONS], *t_done, *t_card0, *t_back;
#define T_RESET() (memset(t_opt, 0, sizeof t_opt), t_done = t_card0 = t_back = NULL)
#define T_OPT(i, o) (t_opt[i] = (o))
#define T_DONE(o) (t_done = (o))
#define T_CARD0(o) (t_card0 = (o))
#define T_BACK(o) (t_back = (o))
#else
#define T_RESET() ((void)0)
#define T_OPT(i, o) ((void)(o))
#define T_DONE(o) ((void)(o))
#define T_CARD0(o) ((void)(o))
#define T_BACK(o) ((void)(o))
#endif

static void refresh(void);

// ---- actions --------------------------------------------------------------------------------

static void send_answer(const char *answer)
{
    char *out = NULL;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bp_answer(s_model, answer, &out);
    xSemaphoreGive(s_lock);
    if (out) {
        if (!net_send(out)) ESP_LOGW(TAG, "answer not sent: bridge offline (the question will time out)");
        bp_free(out);
    }
    refresh();
}

static void on_option(lv_event_t *e)
{
    size_t i = (size_t)(uintptr_t)lv_obj_get_user_data(lv_event_get_target_obj(e));
    char label[160] = "";
    bool multi = false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bp_ask_t *a = bp_current_ask(s_model);
    if (a) {
        const bp_question_t *q = &a->questions[bp_ask_next_question(a)];
        multi = q->multi_select;
        if (i < q->n_options) strlcpy(label, q->options[i].label, sizeof label);
    }
    xSemaphoreGive(s_lock);
    if (!label[0]) return;
    if (multi) {
        if (i < MAX_OPTIONS) s_sel[i] = !s_sel[i];
        refresh();
    } else {
        send_answer(label);
    }
}

static void on_done(lv_event_t *e)
{
    (void)e;
    const char *picked[MAX_OPTIONS];
    size_t n = 0;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bp_ask_t *a = bp_current_ask(s_model);
    char *joined = NULL;
    if (a) {
        const bp_question_t *q = &a->questions[bp_ask_next_question(a)];
        for (size_t i = 0; i < q->n_options && i < MAX_OPTIONS; i++)
            if (s_sel[i]) picked[n++] = q->options[i].label;
        if (n) joined = bp_join_labels(picked, n); // copies the labels, so safe after unlock
    }
    xSemaphoreGive(s_lock);
    if (!joined) return; // nothing selected: Done does nothing
    send_answer(joined);
    bp_free(joined);
}

static void on_decline(lv_event_t *e)
{
    (void)e;
    char *json = NULL;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bp_ask_t *a = bp_current_ask(s_model);
    if (a) {
        json = bp_decline_json(a);
        bp_ask_dismiss(s_model, a->id);
    }
    xSemaphoreGive(s_lock);
    if (json) {
        net_send(json);
        bp_free(json);
    }
    refresh();
}

static void on_card(lv_event_t *e)
{
    size_t i = (size_t)(uintptr_t)lv_obj_get_user_data(lv_event_get_target_obj(e));
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bp_session_t *s;
    size_t n = bp_sessions(s_model, &s);
    if (i < n) {
        strlcpy(s_detail_host, s[i].host, sizeof s_detail_host);
        strlcpy(s_detail_session, s[i].session, sizeof s_detail_session);
    }
    xSemaphoreGive(s_lock);
    s_page = PAGE_DETAIL;
    refresh();
}

static void on_back(lv_event_t *e)
{
    (void)e;
    s_detail_host[0] = s_detail_session[0] = 0;
    s_page = PAGE_LIST;
    refresh();
}

static void on_screen_pressed(lv_event_t *e)
{
    (void)e;
    if (s_page == PAGE_IDLE) refresh(); // a touch wakes the screen
}

// ---- pages ----------------------------------------------------------------------------------

static void build_idle(size_t n_sessions, size_t waiting)
{
    lv_obj_t *ring = lv_obj_create(s_content);
    lv_obj_set_size(ring, 440, 440);
    lv_obj_center(ring);
    lv_obj_set_style_bg_opa(ring, LV_OPA_TRANSP, 0);
    lv_obj_set_style_radius(ring, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(ring, 2, 0);
    lv_obj_set_style_border_color(ring, lv_color_hex(COL_FAINT), 0);
    lv_obj_remove_flag(ring, LV_OBJ_FLAG_SCROLLABLE);
    if (waiting > 0) {
        char num[16];
        snprintf(num, sizeof num, "%u", (unsigned)waiting);
        lv_obj_align(mk_label(s_content, num, &lv_font_montserrat_48, COL_WAITING), LV_ALIGN_CENTER, 0, -14);
        lv_obj_align(mk_label(s_content, "waiting", &lv_font_montserrat_16, COL_MUTED), LV_ALIGN_CENTER, 0, 34);
    } else if (n_sessions > 0) {
        char t[32];
        snprintf(t, sizeof t, "%u sessions", (unsigned)n_sessions);
        lv_obj_center(mk_label(s_content, t, &lv_font_montserrat_14, 0x374151));
    }
}

static void build_list(const bp_session_t *s, size_t n, size_t waiting)
{
    char head[48];
    if (n == 0) snprintf(head, sizeof head, "no sessions");
    else snprintf(head, sizeof head, "%u session%s  %u waiting", (unsigned)n, n == 1 ? "" : "s", (unsigned)waiting);
    lv_obj_align(mk_label(s_content, head, &lv_font_montserrat_14, COL_MUTED), LV_ALIGN_TOP_MID, 0, 26);

    s_list = lv_obj_create(s_content);
    lv_obj_set_size(s_list, 380, 466);
    lv_obj_center(s_list);
    lv_obj_set_style_bg_opa(s_list, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_list, 0, 0);
    lv_obj_set_style_pad_top(s_list, 56, 0);
    lv_obj_set_style_pad_bottom(s_list, 70, 0);
    lv_obj_set_style_pad_row(s_list, 10, 0);
    lv_obj_set_flex_flow(s_list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(s_list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_scrollbar_mode(s_list, LV_SCROLLBAR_MODE_OFF);

    for (size_t i = 0; i < n && i < MAX_ROWS; i++) {
        lv_obj_t *card = lv_obj_create(s_list);
        lv_obj_set_size(card, 330, 74);
        lv_obj_set_style_radius(card, 18, 0);
        lv_obj_set_style_bg_color(card, lv_color_hex(COL_CARD), 0);
        lv_obj_set_style_bg_color(card, lv_color_hex(COL_CARD_PRESSED), LV_STATE_PRESSED);
        lv_obj_set_style_border_width(card, 0, 0);
        lv_obj_set_style_pad_all(card, 12, 0);
        lv_obj_remove_flag(card, LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_add_flag(card, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_set_user_data(card, (void *)(uintptr_t)i);
        lv_obj_add_event_cb(card, on_card, LV_EVENT_CLICKED, NULL);
        if (i == 0) T_CARD0(card);

        lv_obj_t *dot = lv_obj_create(card);
        lv_obj_set_size(dot, 16, 16);
        lv_obj_set_style_radius(dot, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(dot, lv_color_hex(state_colour(s[i].state)), 0);
        lv_obj_set_style_border_width(dot, 0, 0);
        lv_obj_remove_flag(dot, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_align(dot, LV_ALIGN_LEFT_MID, 0, 0);

        char proj[48];
        fit_copy(proj, sizeof proj, s[i].project, 24);
        lv_obj_t *p = mk_label(card, proj, &lv_font_montserrat_20, COL_TEXT);
        lv_obj_align(p, LV_ALIGN_TOP_LEFT, 28, 0);

        char sub[96], ago[16];
        fmt_ago(ago, sizeof ago, s[i].since);
        snprintf(sub, sizeof sub, "%s - %s %s", s[i].host, state_name(s[i].state), ago);
        lv_obj_t *l = mk_label(card, sub, &lv_font_montserrat_14, COL_MUTED);
        lv_obj_align(l, LV_ALIGN_BOTTOM_LEFT, 28, 0);
        s_rows[s_nrows++].sub = l;
    }
}

static void build_question(const bp_ask_t *ask)
{
    size_t qi = bp_ask_next_question(ask);
    const bp_question_t *q = &ask->questions[qi];
    if (strcmp(s_sel_ask, ask->id) != 0 || s_sel_q != qi) {
        memset(s_sel, 0, sizeof s_sel);
        strlcpy(s_sel_ask, ask->id, sizeof s_sel_ask);
        s_sel_q = qi;
    }

    char head[96];
    if (ask->n_questions > 1)
        snprintf(head, sizeof head, "%s - %s   %u/%u", ask->project, ask->host, (unsigned)qi + 1, (unsigned)ask->n_questions);
    else
        snprintf(head, sizeof head, "%s - %s", ask->project, ask->host);
    lv_obj_align(mk_label(s_content, head, &lv_font_montserrat_14, COL_MUTED), LV_ALIGN_TOP_MID, 0, 38);

    char text[216];
    fit_copy(text, sizeof text, q->text, 200);
    lv_obj_t *ql = mk_label(s_content, text, &lv_font_montserrat_20, COL_TEXT);
    lv_label_set_long_mode(ql, LV_LABEL_LONG_MODE_DOTS);
    lv_obj_set_size(ql, 320, 92);
    lv_obj_set_style_text_align(ql, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(ql, LV_ALIGN_TOP_MID, 0, 62);

    size_t shown = q->n_options > MAX_OPTIONS ? MAX_OPTIONS : q->n_options;
    int oh = q->multi_select ? 40 : 48, gap = q->multi_select ? 6 : 8, y = 166;
    for (size_t i = 0; i < shown; i++, y += oh + gap) {
        bool sel = q->multi_select && s_sel[i];
        lv_obj_t *b = lv_button_create(s_content);
        lv_obj_set_size(b, 280, oh);
        lv_obj_align(b, LV_ALIGN_TOP_MID, 0, y);
        lv_obj_set_style_radius(b, 14, 0);
        lv_obj_set_style_bg_color(b, lv_color_hex(sel ? COL_WAITING : COL_CARD_PRESSED), 0);
        lv_obj_set_style_shadow_width(b, 0, 0);
        lv_obj_set_user_data(b, (void *)(uintptr_t)i);
        lv_obj_add_event_cb(b, on_option, LV_EVENT_CLICKED, NULL);
        T_OPT(i, b);
        char lab[48];
        fit_copy(lab, sizeof lab, q->options[i].label, 40);
        lv_obj_t *l = mk_label(b, lab, &lv_font_montserrat_20, sel ? COL_BG : COL_TEXT);
        lv_obj_center(l);
    }
    if (q->multi_select) {
        bool any = false;
        for (size_t i = 0; i < shown; i++) any |= s_sel[i];
        lv_obj_t *d = lv_button_create(s_content);
        lv_obj_set_size(d, 180, 40);
        lv_obj_align(d, LV_ALIGN_TOP_MID, 0, y);
        lv_obj_set_style_radius(d, 14, 0);
        lv_obj_set_style_bg_color(d, lv_color_hex(any ? COL_DONE : COL_CARD), 0);
        lv_obj_set_style_shadow_width(d, 0, 0);
        lv_obj_add_event_cb(d, on_done, LV_EVENT_CLICKED, NULL);
        T_DONE(d);
        lv_obj_center(mk_label(d, "Done", &lv_font_montserrat_20, any ? COL_BG : COL_MUTED));
    }

    lv_obj_t *c = lv_button_create(s_content);
    lv_obj_set_size(c, 170, 34);
    lv_obj_align(c, LV_ALIGN_BOTTOM_MID, 0, -26);
    lv_obj_set_style_radius(c, 17, 0);
    lv_obj_set_style_bg_opa(c, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(c, 1, 0);
    lv_obj_set_style_border_color(c, lv_color_hex(COL_FAINT), 0);
    lv_obj_set_style_shadow_width(c, 0, 0);
    lv_obj_add_event_cb(c, on_decline, LV_EVENT_CLICKED, NULL);
    lv_obj_center(mk_label(c, "on computer", &lv_font_montserrat_14, COL_MUTED));
}

static void build_detail(const bp_session_t *s)
{
    lv_obj_t *back = lv_obj_create(s_content); // the whole screen is the "back" button
    lv_obj_set_size(back, 466, 466);
    lv_obj_set_style_bg_opa(back, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(back, 0, 0);
    lv_obj_remove_flag(back, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(back, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(back, on_back, LV_EVENT_CLICKED, NULL);
    T_BACK(back);

    char proj[48];
    fit_copy(proj, sizeof proj, s->project, 24);
    lv_obj_t *p = mk_label(s_content, proj, &lv_font_montserrat_28, COL_TEXT);
    lv_obj_align(p, LV_ALIGN_CENTER, 0, -70);
    lv_obj_align(mk_label(s_content, s->host, &lv_font_montserrat_20, COL_MUTED), LV_ALIGN_CENTER, 0, -30);

    char st[32];
    snprintf(st, sizeof st, "%s", state_name(s->state));
    lv_obj_align(mk_label(s_content, st, &lv_font_montserrat_24, state_colour(s->state)), LV_ALIGN_CENTER, 0, 20);

    char ago[16], line[48];
    fmt_ago(ago, sizeof ago, s->since);
    snprintf(line, sizeof line, "for %s", ago);
    lv_obj_align(mk_label(s_content, line, &lv_font_montserrat_20, COL_MUTED), LV_ALIGN_CENTER, 0, 58);
    lv_obj_align(mk_label(s_content, "tap to go back", &lv_font_montserrat_14, 0x374151), LV_ALIGN_BOTTOM_MID, 0, -40);
}

// ---- refresh --------------------------------------------------------------------------------

// Redraw the page for the current model. The display lock is held by the caller.
static void refresh(void)
{
    bool is_awake = awake();
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bp_ask_t *ask = bp_current_ask(s_model);
    const bp_session_t *sess;
    size_t n = bp_sessions(s_model, &sess);
    size_t waiting = bp_waiting_count(s_model);

    bool new_ask = ask && strcmp(ask->id, s_prev_ask_id) != 0;
    if (new_ask || waiting > s_prev_waiting) chime_play();
    s_prev_waiting = waiting;
    strlcpy(s_prev_ask_id, ask ? ask->id : "", sizeof s_prev_ask_id);
    if (ask) is_awake = true; // a question keeps the screen up

    const bp_session_t *detail = NULL;
    if (s_detail_session[0])
        for (size_t i = 0; i < n; i++)
            if (!strcmp(sess[i].host, s_detail_host) && !strcmp(sess[i].session, s_detail_session)) detail = &sess[i];

    page_t want;
    if (ask) want = PAGE_QUESTION;
    else if (!is_awake) want = PAGE_IDLE;
    else if (s_page == PAGE_DETAIL && detail) want = PAGE_DETAIL;
    else want = PAGE_LIST;
    if (want != PAGE_DETAIL) s_detail_host[0] = s_detail_session[0] = 0;

    int32_t scroll = (s_list && s_page == PAGE_LIST && want == PAGE_LIST) ? lv_obj_get_scroll_y(s_list) : 0;
    s_list = NULL;
    s_nrows = 0;
    T_RESET();
    lv_obj_clean(s_content);

    const char *tag = "idle";
    switch (want) {
    case PAGE_IDLE: build_idle(n, waiting); break;
    case PAGE_LIST:
        build_list(sess, n, waiting);
        if (scroll) lv_obj_scroll_to_y(s_list, scroll, LV_ANIM_OFF);
        tag = "list";
        break;
    case PAGE_QUESTION: build_question(ask); tag = "question"; break;
    case PAGE_DETAIL: build_detail(detail); tag = "detail"; break;
    }
    s_page = want;
    xSemaphoreGive(s_lock);

    if (!s_link) { // a small red dot at the top: the bridge is unreachable
        lv_obj_t *d = lv_obj_create(s_content);
        lv_obj_set_size(d, 10, 10);
        lv_obj_set_style_radius(d, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(d, lv_color_hex(COL_ERROR), 0);
        lv_obj_set_style_border_width(d, 0, 0);
        lv_obj_remove_flag(d, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_align(d, LV_ALIGN_TOP_MID, 0, 10);
    }
    bsp_display_brightness_set(is_awake ? BRIGHT_AWAKE : BRIGHT_IDLE);
    ui_snapshot_log(s_screen, tag);
}

// Runs every second in the LVGL task (display lock held): tick the clocks, and move between
// awake and asleep without waiting for a model change.
#if CONFIG_CLAUDE_BOARD_SELFTEST
// Every third tick, click something on the current page: the first option of a single-select
// question's second choice, a multi-select's 1st and 3rd option then Done, a card once, then back.
static void selftest_step(void)
{
    static int n, visited_detail;
    if (++n % 3) return;
    if (s_page == PAGE_QUESTION) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        const bp_ask_t *a = bp_current_ask(s_model);
        bool multi = a && a->questions[bp_ask_next_question(a)].multi_select;
        xSemaphoreGive(s_lock);
        if (!multi) {
            if (t_opt[1]) lv_obj_send_event(t_opt[1], LV_EVENT_CLICKED, NULL);
        } else if (!s_sel[0]) {
            if (t_opt[0]) lv_obj_send_event(t_opt[0], LV_EVENT_CLICKED, NULL);
        } else if (!s_sel[2]) {
            if (t_opt[2]) lv_obj_send_event(t_opt[2], LV_EVENT_CLICKED, NULL);
        } else if (t_done) {
            lv_obj_send_event(t_done, LV_EVENT_CLICKED, NULL);
        }
    } else if (s_page == PAGE_LIST && t_card0 && !visited_detail) {
        visited_detail = 1;
        lv_obj_send_event(t_card0, LV_EVENT_CLICKED, NULL);
    } else if (s_page == PAGE_DETAIL && t_back) {
        lv_obj_send_event(t_back, LV_EVENT_CLICKED, NULL);
    }
}
#endif

static void tick(lv_timer_t *t)
{
    (void)t;
#if CONFIG_CLAUDE_BOARD_SELFTEST
    selftest_step();
#endif
    bool is_awake = awake();
    if ((s_page == PAGE_IDLE && is_awake) || (s_page != PAGE_IDLE && s_page != PAGE_QUESTION && !is_awake)) {
        refresh();
        return;
    }
    if (s_page != PAGE_LIST) return;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bp_session_t *s;
    size_t n = bp_sessions(s_model, &s);
    for (size_t i = 0; i < s_nrows && i < n; i++) {
        char ago[16], sub[96];
        fmt_ago(ago, sizeof ago, s[i].since);
        snprintf(sub, sizeof sub, "%s - %s %s", s[i].host, state_name(s[i].state), ago);
        lv_label_set_text(s_rows[i].sub, sub);
    }
    xSemaphoreGive(s_lock);
}

// ---- public ---------------------------------------------------------------------------------

void ui_model_changed(void)
{
    s_last_change_ms = now_ms();
    bsp_display_lock(-1);
    refresh();
    bsp_display_unlock();
}

void ui_set_link(bool connected)
{
    bsp_display_lock(-1);
    s_link = connected;
    refresh();
    bsp_display_unlock();
}

void ui_init(bp_model_t *model, SemaphoreHandle_t model_lock)
{
    s_model = model;
    s_lock = model_lock;
    s_last_change_ms = now_ms();
    bsp_display_lock(-1);
    s_screen = lv_screen_active();
    lv_obj_set_style_bg_color(s_screen, lv_color_hex(COL_BG), 0);
    lv_obj_remove_flag(s_screen, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(s_screen, on_screen_pressed, LV_EVENT_PRESSED, NULL);
    s_content = lv_obj_create(s_screen);
    lv_obj_set_size(s_content, 466, 466);
    lv_obj_set_style_bg_opa(s_content, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_content, 0, 0);
    lv_obj_set_style_pad_all(s_content, 0, 0);
    lv_obj_set_style_radius(s_content, 0, 0);
    lv_obj_remove_flag(s_content, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(s_content, LV_OBJ_FLAG_EVENT_BUBBLE);
    lv_timer_create(tick, 1000, NULL);
    refresh();
    bsp_display_unlock();
}
