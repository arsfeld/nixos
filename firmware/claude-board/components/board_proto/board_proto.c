#include "board_proto.h"

#include <stdlib.h>
#include <string.h>

#include "cJSON.h"

struct bp_model {
    bp_session_t *sessions;
    size_t n_sessions;
    bp_ask_t **asks;
    size_t n_asks;
};

size_t bp_fit(const char *s, size_t max_bytes)
{
    size_t len = strlen(s);
    if (len <= max_bytes) return len;
    size_t n = max_bytes;
    while (n > 0 && ((unsigned char)s[n] & 0xC0) == 0x80) n--; // s[n] continues a character: back up
    return n;
}

void bp_free(void *p) { free(p); }

static char *dup_str(const char *s)
{
    size_t n = strlen(s);
    char *d = malloc(n + 1);
    if (d) memcpy(d, s, n + 1);
    return d;
}

static void copy_field(char *dst, size_t cap, const char *src)
{
    size_t n = bp_fit(src, cap - 1);
    memcpy(dst, src, n);
    dst[n] = 0;
}

static const char *jstr(const cJSON *o, const char *key)
{
    const cJSON *it = cJSON_GetObjectItemCaseSensitive(o, key);
    return cJSON_IsString(it) ? it->valuestring : NULL;
}

// ---- sessions ---------------------------------------------------------------------------

static bp_state_t state_of(const char *s)
{
    if (!strcmp(s, "working")) return ST_WORKING;
    if (!strcmp(s, "waiting")) return ST_WAITING;
    if (!strcmp(s, "done")) return ST_DONE;
    if (!strcmp(s, "error")) return ST_ERROR;
    return ST_IDLE; // "idle" and anything a newer bridge might add
}

static bool parse_session(const cJSON *o, bp_session_t *out)
{
    if (!cJSON_IsObject(o)) return false;
    const char *host = jstr(o, "host"), *session = jstr(o, "session"), *project = jstr(o, "project"),
               *state = jstr(o, "state");
    const cJSON *since = cJSON_GetObjectItemCaseSensitive(o, "since");
    if (!host || !session || !project || !state || !cJSON_IsNumber(since)) return false;
    memset(out, 0, sizeof *out);
    copy_field(out->host, sizeof out->host, host);
    copy_field(out->session, sizeof out->session, session);
    copy_field(out->project, sizeof out->project, project);
    out->state = state_of(state);
    out->since = (int64_t)since->valuedouble;
    return true;
}

static int cmp_session(const void *pa, const void *pb)
{
    const bp_session_t *a = pa, *b = pb;
    int wa = a->state == ST_WAITING, wb = b->state == ST_WAITING;
    if (wa != wb) return wb - wa;
    if (a->since != b->since) return a->since < b->since ? 1 : -1;
    int c = strcmp(a->host, b->host);
    return c ? c : strcmp(a->session, b->session);
}

static void sort_sessions(bp_model_t *m)
{
    if (m->n_sessions > 1) qsort(m->sessions, m->n_sessions, sizeof *m->sessions, cmp_session);
}

// ---- asks -------------------------------------------------------------------------------

static void free_ask(bp_ask_t *a)
{
    if (!a) return;
    for (size_t i = 0; i < a->n_questions; i++) {
        bp_question_t *q = &a->questions[i];
        free(q->text);
        free(q->header);
        for (size_t j = 0; j < q->n_options; j++) {
            free(q->options[j].label);
            free(q->options[j].description);
        }
        free(q->options);
    }
    free(a->questions);
    if (a->answers)
        for (size_t i = 0; i < a->n_questions; i++) free(a->answers[i]);
    free(a->answers);
    free(a);
}

static char *opt_str(const cJSON *o, const char *key)
{
    const char *s = jstr(o, key);
    return s ? dup_str(s) : NULL;
}

// NULL if malformed. On failure everything allocated so far is freed.
static bp_ask_t *parse_ask(const cJSON *o)
{
    const char *id = jstr(o, "id"), *host = jstr(o, "host"), *session = jstr(o, "session"),
               *project = jstr(o, "project");
    const cJSON *qs = cJSON_GetObjectItemCaseSensitive(o, "questions");
    if (!id || !host || !session || !project || !cJSON_IsArray(qs)) return NULL;
    size_t nq = (size_t)cJSON_GetArraySize(qs);
    if (nq == 0) return NULL;

    bp_ask_t *a = calloc(1, sizeof *a);
    if (!a) return NULL;
    copy_field(a->id, sizeof a->id, id);
    copy_field(a->host, sizeof a->host, host);
    copy_field(a->session, sizeof a->session, session);
    copy_field(a->project, sizeof a->project, project);
    a->questions = calloc(nq, sizeof *a->questions);
    a->answers = calloc(nq, sizeof *a->answers);
    if (!a->questions || !a->answers) {
        free_ask(a);
        return NULL;
    }
    a->n_questions = nq; // from here free_ask() frees whatever is filled in

    size_t i = 0;
    const cJSON *qj;
    cJSON_ArrayForEach(qj, qs)
    {
        bp_question_t *q = &a->questions[i++];
        const char *text = jstr(qj, "question");
        const cJSON *opts = cJSON_GetObjectItemCaseSensitive(qj, "options");
        if (!text || !cJSON_IsArray(opts)) {
            free_ask(a);
            return NULL;
        }
        q->text = dup_str(text);
        q->header = opt_str(qj, "header");
        q->multi_select = cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(qj, "multiSelect"));
        size_t no = (size_t)cJSON_GetArraySize(opts);
        q->options = no ? calloc(no, sizeof *q->options) : NULL;
        if (!q->text || (no && !q->options)) {
            free_ask(a);
            return NULL;
        }
        q->n_options = no;
        size_t j = 0;
        const cJSON *oj;
        cJSON_ArrayForEach(oj, opts)
        {
            const char *label = jstr(oj, "label");
            if (!label) {
                free_ask(a);
                return NULL;
            }
            q->options[j].label = dup_str(label);
            q->options[j].description = opt_str(oj, "description");
            j++;
        }
    }
    return a;
}

static bool add_ask(bp_model_t *m, bp_ask_t *a)
{
    bp_ask_t **grown = realloc(m->asks, (m->n_asks + 1) * sizeof *grown);
    if (!grown) return false;
    m->asks = grown;
    m->asks[m->n_asks++] = a;
    return true;
}

static void clear_asks(bp_model_t *m)
{
    for (size_t i = 0; i < m->n_asks; i++) free_ask(m->asks[i]);
    free(m->asks);
    m->asks = NULL;
    m->n_asks = 0;
}

// ---- model ------------------------------------------------------------------------------

bp_model_t *bp_model_new(void) { return calloc(1, sizeof(bp_model_t)); }

void bp_model_free(bp_model_t *m)
{
    if (!m) return;
    clear_asks(m);
    free(m->sessions);
    free(m);
}

static int apply_state(bp_model_t *m, const cJSON *root)
{
    const cJSON *arr = cJSON_GetObjectItemCaseSensitive(root, "sessions");
    if (!cJSON_IsArray(arr)) return BP_ERR;
    size_t n = (size_t)cJSON_GetArraySize(arr);
    bp_session_t *fresh = n ? calloc(n, sizeof *fresh) : NULL;
    if (n && !fresh) return BP_ERR;
    size_t i = 0;
    const cJSON *sj;
    cJSON_ArrayForEach(sj, arr)
    {
        if (!parse_session(sj, &fresh[i++])) { // all or nothing: a bad element changes nothing
            free(fresh);
            return BP_ERR;
        }
    }
    free(m->sessions);
    m->sessions = fresh;
    m->n_sessions = n;
    sort_sessions(m);
    clear_asks(m);
    return BP_OK;
}

static int apply_upsert(bp_model_t *m, const cJSON *root)
{
    bp_session_t s;
    if (!parse_session(cJSON_GetObjectItemCaseSensitive(root, "session"), &s)) return BP_ERR;
    for (size_t i = 0; i < m->n_sessions; i++) {
        if (!strcmp(m->sessions[i].host, s.host) && !strcmp(m->sessions[i].session, s.session)) {
            m->sessions[i] = s;
            sort_sessions(m);
            return BP_OK;
        }
    }
    bp_session_t *grown = realloc(m->sessions, (m->n_sessions + 1) * sizeof *grown);
    if (!grown) return BP_ERR;
    m->sessions = grown;
    m->sessions[m->n_sessions++] = s;
    sort_sessions(m);
    return BP_OK;
}

static int apply_remove(bp_model_t *m, const cJSON *root)
{
    const char *host = jstr(root, "host"), *session = jstr(root, "session");
    if (!host || !session) return BP_ERR;
    for (size_t i = 0; i < m->n_sessions; i++) {
        if (!strcmp(m->sessions[i].host, host) && !strcmp(m->sessions[i].session, session)) {
            memmove(&m->sessions[i], &m->sessions[i + 1], (m->n_sessions - i - 1) * sizeof *m->sessions);
            m->n_sessions--;
            break;
        }
    }
    return BP_OK;
}

static int apply_question(bp_model_t *m, const cJSON *root)
{
    bp_ask_t *a = parse_ask(root);
    if (!a) return BP_ERR;
    for (size_t i = 0; i < m->n_asks; i++) {
        if (!strcmp(m->asks[i]->id, a->id)) { // already held: a re-send after a reconnect
            free_ask(a);
            return BP_OK;
        }
    }
    if (!add_ask(m, a)) {
        free_ask(a);
        return BP_ERR;
    }
    return BP_OK;
}

static int apply_question_clear(bp_model_t *m, const cJSON *root)
{
    const char *id = jstr(root, "id");
    if (!id) return BP_ERR;
    for (size_t i = 0; i < m->n_asks; i++) {
        if (!strcmp(m->asks[i]->id, id)) {
            free_ask(m->asks[i]);
            memmove(&m->asks[i], &m->asks[i + 1], (m->n_asks - i - 1) * sizeof *m->asks);
            m->n_asks--;
            break;
        }
    }
    return BP_OK;
}

int bp_apply(bp_model_t *m, const char *json, size_t len)
{
    cJSON *root = cJSON_ParseWithLength(json, len);
    if (!root) return BP_ERR;
    int rc = BP_ERR;
    const char *t = cJSON_IsObject(root) ? jstr(root, "t") : NULL;
    if (t) {
        if (!strcmp(t, "state")) rc = apply_state(m, root);
        else if (!strcmp(t, "upsert")) rc = apply_upsert(m, root);
        else if (!strcmp(t, "remove")) rc = apply_remove(m, root);
        else if (!strcmp(t, "question")) rc = apply_question(m, root);
        else if (!strcmp(t, "question_clear")) rc = apply_question_clear(m, root);
        else rc = BP_IGNORED;
    }
    cJSON_Delete(root);
    return rc;
}

size_t bp_sessions(const bp_model_t *m, const bp_session_t **out)
{
    *out = m->sessions;
    return m->n_sessions;
}

size_t bp_waiting_count(const bp_model_t *m)
{
    size_t n = 0;
    for (size_t i = 0; i < m->n_sessions; i++) n += m->sessions[i].state == ST_WAITING;
    return n;
}

size_t bp_ask_count(const bp_model_t *m) { return m->n_asks; }

size_t bp_ask_next_question(const bp_ask_t *a) { return a->n_answered; }

const bp_ask_t *bp_current_ask(const bp_model_t *m)
{
    for (size_t i = 0; i < m->n_asks; i++)
        if (m->asks[i]->n_answered < m->asks[i]->n_questions) return m->asks[i];
    return NULL;
}

// ---- answers ----------------------------------------------------------------------------

// Print a cJSON tree into a buffer we own, so callers free it with bp_free() whatever cJSON's
// allocator hooks are.
static char *print_owned(cJSON *root)
{
    char *printed = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (!printed) return NULL;
    char *own = dup_str(printed);
    cJSON_free(printed);
    return own;
}

int bp_answer(bp_model_t *m, const char *answer, char **out)
{
    *out = NULL;
    bp_ask_t *a = NULL;
    for (size_t i = 0; i < m->n_asks; i++)
        if (m->asks[i]->n_answered < m->asks[i]->n_questions) {
            a = m->asks[i];
            break;
        }
    if (!a) return -1;
    char *copy = dup_str(answer);
    if (!copy) return -1;
    a->answers[a->n_answered++] = copy;
    if (a->n_answered < a->n_questions) return 0;

    cJSON *root = cJSON_CreateObject();
    cJSON *answers = cJSON_CreateObject();
    if (!root || !answers) {
        cJSON_Delete(root);
        cJSON_Delete(answers);
        return -1;
    }
    cJSON_AddStringToObject(root, "t", "answer");
    cJSON_AddStringToObject(root, "id", a->id);
    for (size_t i = 0; i < a->n_questions; i++)
        cJSON_AddItemToObject(answers, a->questions[i].text, cJSON_CreateString(a->answers[i])); // exact text is the key
    cJSON_AddItemToObject(root, "answers", answers);
    *out = print_owned(root);
    return *out ? 1 : -1;
}

char *bp_decline_json(const bp_ask_t *a)
{
    cJSON *root = cJSON_CreateObject();
    if (!root) return NULL;
    cJSON_AddStringToObject(root, "t", "decline");
    cJSON_AddStringToObject(root, "id", a->id);
    return print_owned(root);
}

char *bp_join_labels(const char *const *labels, size_t n)
{
    size_t total = 1;
    for (size_t i = 0; i < n; i++) total += strlen(labels[i]) + 1;
    char *s = malloc(total);
    if (!s) return NULL;
    char *p = s;
    for (size_t i = 0; i < n; i++) {
        if (i) *p++ = ',';
        size_t l = strlen(labels[i]);
        memcpy(p, labels[i], l);
        p += l;
    }
    *p = 0;
    return s;
}
