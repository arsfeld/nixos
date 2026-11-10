// board_proto: the board's side of the claude-board bridge protocol (docs/superpowers/specs/
// 2026-11-09-claude-board-design.md). Pure C over cJSON, no ESP-IDF calls, so it is tested on the
// host (`just board test`).
//
// Server -> board messages are applied to a model with bp_apply(); the UI reads sessions and the
// current question from it. Answers are built by bp_answer(), which also owns the multi-question
// bookkeeping.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { ST_IDLE, ST_WORKING, ST_WAITING, ST_DONE, ST_ERROR } bp_state_t;

#define BP_HOST_MAX 24
#define BP_SESSION_MAX 40
#define BP_PROJECT_MAX 40
#define BP_ID_MAX 40

// Result of bp_apply().
#define BP_OK 0
#define BP_IGNORED 1 // a well-formed message of a kind this firmware does not know
#define BP_ERR (-1)  // malformed; the model is unchanged

typedef struct {
    char host[BP_HOST_MAX];
    char session[BP_SESSION_MAX];
    char project[BP_PROJECT_MAX];
    bp_state_t state;
    int64_t since; // unix seconds of the last state change
} bp_session_t;

typedef struct {
    char *label;
    char *description; // NULL when absent or null on the wire
} bp_option_t;

typedef struct {
    char *text; // the exact question text: the answer key, never truncated
    char *header; // NULL when absent
    bp_option_t *options;
    size_t n_options;
    bool multi_select;
} bp_question_t;

typedef struct {
    char id[BP_ID_MAX];
    char host[BP_HOST_MAX];
    char session[BP_SESSION_MAX];
    char project[BP_PROJECT_MAX];
    bp_question_t *questions;
    size_t n_questions;
    char **answers; // one per question, NULL until answered
    size_t n_answered;
} bp_ask_t;

typedef struct bp_model bp_model_t;

bp_model_t *bp_model_new(void);
void bp_model_free(bp_model_t *m);

// Apply one server message (a JSON text frame). BP_OK, BP_IGNORED or BP_ERR.
// A "state" snapshot replaces every session and drops every held question: the bridge re-sends
// the pending ones straight after it.
int bp_apply(bp_model_t *m, const char *json, size_t len);

// All sessions, waiting first and then newest state change first. The pointer is valid until the
// next bp_apply().
size_t bp_sessions(const bp_model_t *m, const bp_session_t **out);
size_t bp_waiting_count(const bp_model_t *m);

// The oldest question still waiting for an answer, or NULL.
const bp_ask_t *bp_current_ask(const bp_model_t *m);
// Questions held, including fully answered ones awaiting the bridge's question_clear.
size_t bp_ask_count(const bp_model_t *m);
// Index of the question of `a` that is waiting for an answer.
size_t bp_ask_next_question(const bp_ask_t *a);

// Record the answer to the current question: its option label, or the labels of a multi-select
// question joined with bp_join_labels(). Returns 0 while more questions of the ask remain
// (*out = NULL), 1 when it was the last (*out = the answer message to send, free with bp_free),
// -1 when no question is waiting (*out = NULL).
int bp_answer(bp_model_t *m, const char *answer, char **out);

// The message that declines to answer ("answer on computer"). Free with bp_free.
char *bp_decline_json(const bp_ask_t *a);

// Labels joined with "," as the question tool expects for multi-select. Free with bp_free.
char *bp_join_labels(const char *const *labels, size_t n);

// How many bytes of `utf8` (at most max_bytes) to show: never ends in the middle of a character.
size_t bp_fit(const char *utf8, size_t max_bytes);

void bp_free(void *p);

#ifdef __cplusplus
}
#endif
