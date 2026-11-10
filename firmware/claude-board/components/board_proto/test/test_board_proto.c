// Host tests for board_proto. Run with `just board test`.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "board_proto.h"
#include "cJSON.h"

static int passes, failures;

#define CHECK(cond)                                                                       \
    do {                                                                                  \
        if (!(cond)) {                                                                    \
            printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                      \
            failures++;                                                                   \
            return;                                                                       \
        }                                                                                 \
    } while (0)

static char *fixture(const char *name)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s.json", FIX_DIR, name);
    FILE *f = fopen(path, "rb");
    if (!f) {
        printf("  cannot open %s\n", path);
        exit(2);
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)n + 1);
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) exit(2);
    buf[n] = 0;
    fclose(f);
    return buf;
}

static int apply_fixture(bp_model_t *m, const char *name)
{
    char *j = fixture(name);
    int rc = bp_apply(m, j, strlen(j));
    free(j);
    return rc;
}

static int apply_str(bp_model_t *m, const char *j) { return bp_apply(m, j, strlen(j)); }

static bool utf8_valid(const char *s)
{
    const unsigned char *p = (const unsigned char *)s;
    while (*p) {
        int n = *p < 0x80 ? 1 : (*p >> 5) == 6 ? 2 : (*p >> 4) == 14 ? 3 : (*p >> 3) == 30 ? 4 : 0;
        if (!n) return false;
        for (int i = 1; i < n; i++)
            if ((p[i] & 0xC0) != 0x80) return false;
        p += n;
    }
    return true;
}

static void applies_state_snapshot(void)
{
    bp_model_t *m = bp_model_new();
    CHECK(apply_fixture(m, "state") == BP_OK);
    const bp_session_t *s;
    CHECK(bp_sessions(m, &s) == 3);
    bool found = false;
    for (size_t i = 0; i < 3; i++)
        if (!strcmp(s[i].session, "s-1")) {
            found = true;
            CHECK(!strcmp(s[i].host, "raider"));
            CHECK(!strcmp(s[i].project, "nixos"));
            CHECK(s[i].state == ST_WORKING);
            CHECK(s[i].since == 1000);
        }
    CHECK(found);
    CHECK(bp_waiting_count(m) == 1);
    bp_model_free(m);
}

static void sorts_waiting_first_then_newest(void)
{
    bp_model_t *m = bp_model_new();
    apply_fixture(m, "state");
    const bp_session_t *s;
    bp_sessions(m, &s);
    CHECK(!strcmp(s[0].session, "s-2")); // waiting
    CHECK(!strcmp(s[1].session, "s-3")); // done, since 1200
    CHECK(!strcmp(s[2].session, "s-1")); // working, since 1000
    bp_model_free(m);
}

static void upsert_replaces_and_remove_deletes(void)
{
    bp_model_t *m = bp_model_new();
    apply_fixture(m, "state");
    CHECK(apply_fixture(m, "upsert") == BP_OK);
    const bp_session_t *s;
    CHECK(bp_sessions(m, &s) == 3);
    CHECK(!strcmp(s[1].session, "s-1")); // error, since 1300, now ahead of s-3
    CHECK(s[1].state == ST_ERROR);
    CHECK(apply_fixture(m, "remove") == BP_OK);
    CHECK(bp_sessions(m, &s) == 2);
    for (size_t i = 0; i < 2; i++) CHECK(strcmp(s[i].session, "s-1") != 0);
    bp_model_free(m);
}

static void question_message_sets_current_ask(void)
{
    bp_model_t *m = bp_model_new();
    CHECK(bp_current_ask(m) == NULL);
    CHECK(apply_fixture(m, "question_single") == BP_OK);
    const bp_ask_t *a = bp_current_ask(m);
    CHECK(a != NULL);
    CHECK(!strcmp(a->id, "00000000000000000000000000000001"));
    CHECK(!strcmp(a->host, "galactica"));
    CHECK(!strcmp(a->project, "plab"));
    CHECK(a->n_questions == 1);
    CHECK(!strcmp(a->questions[0].text, "Which colour?"));
    CHECK(!strcmp(a->questions[0].header, "Colour"));
    CHECK(a->questions[0].n_options == 2);
    CHECK(!strcmp(a->questions[0].options[1].label, "Blue"));
    CHECK(a->questions[0].options[1].description == NULL); // null on the wire
    CHECK(!a->questions[0].multi_select);
    bp_model_free(m);
}

static void question_clear_clears_only_the_matching_id(void)
{
    bp_model_t *m = bp_model_new();
    apply_fixture(m, "question_single");
    apply_fixture(m, "question_multi");
    CHECK(bp_ask_count(m) == 2);
    CHECK(apply_fixture(m, "question_clear") == BP_OK); // id ...01
    CHECK(bp_ask_count(m) == 1);
    CHECK(!strcmp(bp_current_ask(m)->id, "00000000000000000000000000000002"));
    bp_model_free(m);
}

static void state_snapshot_resets_stale_questions(void)
{
    // The bridge re-sends every pending question right after a snapshot, so a question that
    // was cleared while the board was offline must not survive the reconnect.
    bp_model_t *m = bp_model_new();
    apply_fixture(m, "question_single");
    apply_fixture(m, "state");
    CHECK(bp_current_ask(m) == NULL);
    bp_model_free(m);
}

static void duplicate_question_id_is_ignored(void)
{
    bp_model_t *m = bp_model_new();
    apply_fixture(m, "question_single");
    apply_fixture(m, "question_single");
    CHECK(bp_ask_count(m) == 1);
    bp_model_free(m);
}

static void malformed_json_returns_error_and_keeps_the_model(void)
{
    bp_model_t *m = bp_model_new();
    apply_fixture(m, "state");
    CHECK(apply_str(m, "{not json") == BP_ERR);
    CHECK(apply_str(m, "") == BP_ERR);
    CHECK(apply_str(m, "[1,2]") == BP_ERR);
    CHECK(apply_str(m, "{\"t\":\"upsert\"}") == BP_ERR);
    CHECK(apply_str(m, "{\"t\":\"question\",\"id\":\"x\"}") == BP_ERR);
    // One bad element must not half-apply a snapshot.
    CHECK(apply_str(m, "{\"t\":\"state\",\"sessions\":[{\"host\":\"a\",\"session\":\"b\",\"project\":\"c\",\"state\":\"idle\",\"since\":1},{\"host\":\"only\"}]}") == BP_ERR);
    const bp_session_t *s;
    CHECK(bp_sessions(m, &s) == 3);
    CHECK(apply_str(m, "{\"t\":\"nonsense\"}") == BP_IGNORED);
    bp_model_free(m);
}

static void unknown_state_maps_to_idle(void)
{
    bp_model_t *m = bp_model_new();
    CHECK(apply_str(m, "{\"t\":\"upsert\",\"session\":{\"host\":\"h\",\"session\":\"s\",\"project\":\"p\",\"state\":\"levitating\",\"since\":5}}") == BP_OK);
    const bp_session_t *s;
    bp_sessions(m, &s);
    CHECK(s[0].state == ST_IDLE);
    bp_model_free(m);
}

static void answer_json_uses_exact_question_text_and_label(void)
{
    bp_model_t *m = bp_model_new();
    apply_fixture(m, "question_single");
    char *out = NULL;
    CHECK(bp_answer(m, "Blue", &out) == 1);
    CHECK(out != NULL);
    CHECK(!strcmp(out, "{\"t\":\"answer\",\"id\":\"00000000000000000000000000000001\",\"answers\":{\"Which colour?\":\"Blue\"}}"));
    bp_free(out);
    bp_model_free(m);
}

static void unicode_and_emoji_round_trip_in_the_answer_key(void)
{
    const char *text = "\xf0\x9f\x8e\xa8 Cu\xc3\xa1l es tu color? e\xcc\x81\xe2\x80\x8d\xf0\x9f\x99\x82";
    bp_model_t *m = bp_model_new();
    apply_fixture(m, "question_unicode");
    CHECK(!strcmp(bp_current_ask(m)->questions[0].text, text));
    char *out = NULL;
    CHECK(bp_answer(m, "\xce\x91 \xce\xb2 \xe2\x9c\x93", &out) == 1);
    cJSON *j = cJSON_Parse(out);
    CHECK(j != NULL);
    cJSON *answers = cJSON_GetObjectItemCaseSensitive(j, "answers");
    CHECK(answers && answers->child);
    CHECK(!strcmp(answers->child->string, text)); // byte-exact key
    CHECK(!strcmp(answers->child->valuestring, "\xce\x91 \xce\xb2 \xe2\x9c\x93"));
    cJSON_Delete(j);
    bp_free(out);
    bp_model_free(m);
}

static void very_long_question_is_stored_whole_and_the_key_is_not_truncated(void)
{
    enum { N = 5000 };
    char *msg = malloc(N + 400);
    char *text = malloc(N + 1);
    memset(text, 'x', N);
    text[N] = 0;
    snprintf(msg, N + 400,
             "{\"t\":\"question\",\"id\":\"l\",\"host\":\"h\",\"session\":\"s\",\"project\":\"p\","
             "\"questions\":[{\"question\":\"%s\",\"header\":null,\"options\":[{\"label\":\"A\",\"description\":null}],\"multiSelect\":false}]}",
             text);
    bp_model_t *m = bp_model_new();
    CHECK(apply_str(m, msg) == BP_OK);
    CHECK(strlen(bp_current_ask(m)->questions[0].text) == N);
    char *out = NULL;
    CHECK(bp_answer(m, "A", &out) == 1);
    cJSON *j = cJSON_Parse(out);
    CHECK(j != NULL);
    cJSON *answers = cJSON_GetObjectItemCaseSensitive(j, "answers");
    CHECK(strlen(answers->child->string) == N);
    cJSON_Delete(j);
    bp_free(out);
    bp_model_free(m);
    free(msg);
    free(text);
}

static void answer_for_the_second_question_waits_until_all_are_answered(void)
{
    bp_model_t *m = bp_model_new();
    apply_fixture(m, "question_multi");
    char *out = NULL;
    CHECK(bp_answer(m, "Pear", &out) == 0);
    CHECK(out == NULL);
    const bp_ask_t *a = bp_current_ask(m);
    CHECK(a != NULL);
    CHECK(bp_ask_next_question(a) == 1);
    CHECK(bp_answer(m, "Nuts,Honey", &out) == 1);
    CHECK(out != NULL);
    cJSON *j = cJSON_Parse(out);
    cJSON *answers = cJSON_GetObjectItemCaseSensitive(j, "answers");
    CHECK(!strcmp(cJSON_GetObjectItemCaseSensitive(answers, "Which fruit?")->valuestring, "Pear"));
    CHECK(!strcmp(cJSON_GetObjectItemCaseSensitive(answers, "Which toppings?")->valuestring, "Nuts,Honey"));
    cJSON_Delete(j);
    bp_free(out);
    CHECK(bp_current_ask(m) == NULL); // answered; waiting only for the bridge's clear
    bp_model_free(m);
}

static void answer_with_no_pending_ask_is_an_error(void)
{
    bp_model_t *m = bp_model_new();
    char *out = (char *)0x1;
    CHECK(bp_answer(m, "x", &out) == -1);
    CHECK(out == NULL);
    bp_model_free(m);
}

static void multi_select_labels_join_with_commas(void)
{
    const char *two[] = {"Nuts", "Honey"};
    char *s = bp_join_labels(two, 2);
    CHECK(!strcmp(s, "Nuts,Honey"));
    bp_free(s);
    s = bp_join_labels(two, 1);
    CHECK(!strcmp(s, "Nuts"));
    bp_free(s);
    s = bp_join_labels(two, 0);
    CHECK(!strcmp(s, ""));
    bp_free(s);
}

static void decline_json_names_the_ask(void)
{
    bp_model_t *m = bp_model_new();
    apply_fixture(m, "question_single");
    char *out = bp_decline_json(bp_current_ask(m));
    CHECK(!strcmp(out, "{\"t\":\"decline\",\"id\":\"00000000000000000000000000000001\"}"));
    bp_free(out);
    bp_model_free(m);
}

static void dismissed_question_is_not_current_but_is_held_until_cleared(void)
{
    bp_model_t *m = bp_model_new();
    apply_fixture(m, "question_single");
    apply_fixture(m, "question_multi");
    bp_ask_dismiss(m, "00000000000000000000000000000001");
    CHECK(bp_ask_count(m) == 2);
    CHECK(!strcmp(bp_current_ask(m)->id, "00000000000000000000000000000002")); // moves on to the next
    bp_ask_dismiss(m, "no-such-id");                                          // harmless
    CHECK(bp_ask_count(m) == 2);
    char *out = NULL;
    CHECK(bp_answer(m, "Pear", &out) == 0); // answers go to the question being shown, not the dismissed one
    apply_fixture(m, "question_clear");     // the bridge clears ...01
    CHECK(bp_ask_count(m) == 1);
    bp_model_free(m);
}

static void fit_never_splits_a_utf8_sequence(void)
{
    const char *s = "a\xc3\xa9\xe6\x97\xa5\xf0\x9f\x99\x82" "b"; // a é 日 🙂 b : 11 bytes
    CHECK(bp_fit(s, 100) == 11);
    CHECK(bp_fit(s, 2) == 1);
    CHECK(bp_fit(s, 3) == 3);
    CHECK(bp_fit(s, 5) == 3);
    CHECK(bp_fit(s, 6) == 6);
    CHECK(bp_fit(s, 9) == 6);
    CHECK(bp_fit(s, 10) == 10);
    CHECK(bp_fit(s, 0) == 0);
    for (size_t max = 0; max <= 12; max++) {
        size_t n = bp_fit(s, max);
        CHECK(n <= max);
        CHECK(((unsigned char)s[n] & 0xC0) != 0x80); // never ends mid-sequence
    }
}

static void long_fields_are_truncated_on_a_character_boundary(void)
{
    char msg[1024];
    char proj[400] = "";
    for (int i = 0; i < 90; i++) strcat(proj, "\xf0\x9f\x99\x82"); // 360 bytes of emoji
    snprintf(msg, sizeof msg, "{\"t\":\"upsert\",\"session\":{\"host\":\"%s\",\"session\":\"s\",\"project\":\"%s\",\"state\":\"idle\",\"since\":1}}", proj, proj);
    bp_model_t *m = bp_model_new();
    CHECK(apply_str(m, msg) == BP_OK);
    const bp_session_t *s;
    bp_sessions(m, &s);
    CHECK(strlen(s[0].project) <= sizeof s[0].project - 1);
    CHECK(strlen(s[0].host) <= sizeof s[0].host - 1);
    CHECK(utf8_valid(s[0].project));
    CHECK(utf8_valid(s[0].host));
    CHECK(strlen(s[0].project) > 0);
    bp_model_free(m);
}

#define RUN(t)                                                                            \
    do {                                                                                  \
        int before = failures;                                                            \
        t();                                                                              \
        if (failures == before) { passes++; printf("ok   %s\n", #t); }                    \
        else printf("FAIL %s\n", #t);                                                     \
    } while (0)

int main(void)
{
    RUN(applies_state_snapshot);
    RUN(sorts_waiting_first_then_newest);
    RUN(upsert_replaces_and_remove_deletes);
    RUN(question_message_sets_current_ask);
    RUN(question_clear_clears_only_the_matching_id);
    RUN(state_snapshot_resets_stale_questions);
    RUN(duplicate_question_id_is_ignored);
    RUN(malformed_json_returns_error_and_keeps_the_model);
    RUN(unknown_state_maps_to_idle);
    RUN(answer_json_uses_exact_question_text_and_label);
    RUN(unicode_and_emoji_round_trip_in_the_answer_key);
    RUN(very_long_question_is_stored_whole_and_the_key_is_not_truncated);
    RUN(answer_for_the_second_question_waits_until_all_are_answered);
    RUN(answer_with_no_pending_ask_is_an_error);
    RUN(multi_select_labels_join_with_commas);
    RUN(decline_json_names_the_ask);
    RUN(dismissed_question_is_not_current_but_is_held_until_cleared);
    RUN(fit_never_splits_a_utf8_sequence);
    RUN(long_fields_are_truncated_on_a_character_boundary);
    printf("---- %d passed, %d failed\n", passes, failures);
    return failures ? 1 : 0;
}
