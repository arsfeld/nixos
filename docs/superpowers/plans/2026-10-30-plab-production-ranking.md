# plab production-style ranking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rank plab's cards by seeders weighted by how each release was produced (industrial / pro_artistic / amateur), as judged once per release by OpenRouter's Jev decisions API.

**Architecture:** A new `classify.py` wraps one Jev decisions call. `refresh()` calls it for every topic that lacks a stored `production` and saves the result in `cache.json`. `page.render()` sorts by `seeders × WEIGHT[class]` and labels each card.

**Tech Stack:** Python 3 stdlib only (urllib, json, unittest), NixOS module, sops-nix.

Spec: `docs/superpowers/specs/2026-10-30-plab-production-ranking-design.md`

## Global Constraints

- All code lives in `hosts/galactica/services/plab/`. Stdlib only; no new Python dependencies.
- Run tests from that directory with `python3 -m unittest -v`. All 158 existing tests must keep passing.
- Classes are exactly `industrial`, `pro_artistic`, `amateur`. The labels shown on cards are `industrial`, `artistic`, `amateur`.
- Weights: amateur 1.5, pro_artistic 1.0, unclassified 1.0, industrial 0.25.
- The default Jev model is `typesafe/jev-1.13`, overridable with `PLAB_JEV_MODEL`.
- Classification never fails a refresh. A failed or skipped classification leaves the topic without a `production` key.
- No key file means no classification and unchanged behaviour.
- Commits are conventional, `feat(galactica): plab …`, straight to master, with no mention of Claude.

---

### Task 1: `classify.py`, the Jev client

**Files:**
- Create: `hosts/galactica/services/plab/classify.py`
- Test: `hosts/galactica/services/plab/test_classify.py`

**Interfaces:**
- Produces: `classify.MODEL = "typesafe/jev-1.13"`, `classify.CRITERIA` (a dict whose keys are the three classes), `classify.Classifier(api_key, model=MODEL, post=post_json)` and its method `.classify(title: str, category: str) -> {"class": str, "confidence": Any}`. The method raises `ValueError` on an unknown choice and `KeyError`/`TypeError` on a malformed reply.

- [ ] **Step 1: Write the failing test**

`hosts/galactica/services/plab/test_classify.py`:

```python
import unittest

import classify


class FakePost:
    def __init__(self, answer):
        self.answer = answer
        self.calls = []

    def __call__(self, url, body, headers):
        self.calls.append((url, body, headers))
        return {"answers": {"production": self.answer}}


class Classify(unittest.TestCase):
    def test_request(self):
        post = FakePost({"choice": "amateur", "confidence": 0.9})
        classify.Classifier("sk-key", post=post).classify("[OnlyFans.com] Couple - Morning", "Clips and siterips")
        url, body, headers = post.calls[0]
        self.assertEqual(url, "https://openrouter.ai/api/alpha/decisions")
        self.assertEqual(headers, {"Authorization": "Bearer sk-key"})
        self.assertEqual(body["model"], "typesafe/jev-1.13")
        self.assertEqual(body["state"], {"title": "[OnlyFans.com] Couple - Morning",
                                         "category": "Clips and siterips"})
        question = body["questions"]["production"]
        self.assertEqual(question["type"], "choice")
        self.assertTrue(question["instructions"])
        self.assertEqual(set(question["criteria"]), {"industrial", "pro_artistic", "amateur"})

    def test_model_override(self):
        post = FakePost({"choice": "industrial"})
        classify.Classifier("k", model="other/model", post=post).classify("t", "c")
        self.assertEqual(post.calls[0][1]["model"], "other/model")

    def test_answer(self):
        post = FakePost({"choice": "pro_artistic", "confidence": "high"})
        out = classify.Classifier("k", post=post).classify("[X-Art.com] A - B", "Clips and siterips")
        self.assertEqual(out, {"class": "pro_artistic", "confidence": "high"})

    def test_missing_confidence_is_none(self):
        out = classify.Classifier("k", post=FakePost({"choice": "industrial"})).classify("t", "c")
        self.assertEqual(out, {"class": "industrial", "confidence": None})

    def test_unknown_choice_raises(self):
        with self.assertRaises(ValueError):
            classify.Classifier("k", post=FakePost({"choice": "none"})).classify("t", "c")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd hosts/galactica/services/plab && python3 -m unittest -v test_classify`
Expected: an ERROR with `ModuleNotFoundError: No module named 'classify'`.

- [ ] **Step 3: Write the implementation**

`hosts/galactica/services/plab/classify.py`:

```python
"""Jev's verdict on how a release was produced, judged from its title; the page ranks by it.

One OpenRouter decisions call per release, made once: refresh stores the answer in
cache.json. Design: docs/superpowers/specs/2026-10-30-plab-production-ranking-design.md
"""
import json
import urllib.request

DECISIONS_URL = "https://openrouter.ai/api/alpha/decisions"
MODEL = "typesafe/jev-1.13"

INSTRUCTIONS = (
    "How was this adult video release produced? Judge from the release title: a leading "
    "[bracket] usually names the studio or site, a trailing [bracket] lists tags, and the "
    "category is the tracker forum group it was posted in."
)

# The examples come from what was actually added from plab versus what was skipped.
CRITERIA = {
    "industrial": (
        "Mass-produced commercial porn: gonzo, anal-focused, taboo/family-roleplay or casting "
        "studios and networks, e.g. LegalPorno/AnalVids/PornBox, Tushy, Woodman Casting, "
        "TeamSkeet, Family Therapy, Backroom Casting Couch, Brazzers."
    ),
    "pro_artistic": (
        "Professionally produced but intimate, romantic or artistic, e.g. Erika Lust, X-Art, "
        "SexArt/MetArt, Bellesa, Frolicme, Viv Thomas."
    ),
    "amateur": (
        "Homemade or creator-run: real couples, amateurs, OnlyFans/ManyVids/Pornhub creators "
        "filming themselves, home or archive footage."
    ),
}


def post_json(url, body, headers, timeout=120):
    req = urllib.request.Request(
        url, json.dumps(body).encode(), {"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


class Classifier:
    def __init__(self, api_key, model=MODEL, post=post_json):
        self.headers = {"Authorization": f"Bearer {api_key}"}
        self.model = model
        self.post = post

    def classify(self, title, category):
        """{"class": one of CRITERIA, "confidence": Jev's, or None}. Raises on a bad reply."""
        d = self.post(DECISIONS_URL, {
            "model": self.model,
            "state": {"title": title, "category": category},
            "questions": {"production": {"type": "choice", "instructions": INSTRUCTIONS,
                                         "criteria": CRITERIA}},
        }, self.headers)
        answer = d["answers"]["production"]
        if answer.get("choice") not in CRITERIA:
            raise ValueError(f"unexpected production choice: {answer.get('choice')!r}")
        return {"class": answer["choice"], "confidence": answer.get("confidence")}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd hosts/galactica/services/plab && python3 -m unittest -v test_classify && python3 -m unittest`
Expected: the 5 new tests pass, and the full suite is OK.

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/classify.py hosts/galactica/services/plab/test_classify.py
git commit -m "feat(galactica): plab Jev production classifier"
```

---

### Task 2: Classify topics during refresh

**Files:**
- Modify: `hosts/galactica/services/plab/main.py`. Touch `refresh` (topic loop), `run_refresh` and `main()`, add `make_classifier`, and extend the module docstring.
- Test: `hosts/galactica/services/plab/test_main.py`

**Interfaces:**
- Consumes: `classify.Classifier(api_key, model).classify(title, category)` and `classify.MODEL` from Task 1, plus `forums.category(forum_id) -> str`.
- Produces:
  - `main.refresh(..., classify=None)`, where `classify` is any `(title, category) -> dict` callable.
  - `main.run_refresh(..., classify=None)`.
  - `main.make_classifier(key_file=None, model=None) -> callable | None`.
  - Topics in `cache.json` may carry `"production": {"class": str, "confidence": Any}`.

- [ ] **Step 1: Write the failing tests**

Add to the `Refresh` class in `test_main.py`, after `test_search_login_error_aborts_refresh`:

```python
    def test_classifies_new_topics(self):
        calls = []

        def classify(title, category):
            calls.append((title, category))
            return {"class": "amateur", "confidence": 0.8}

        main.refresh(FakeLab([row(1, "[OnlyFans.com] A")]), self.store, sleep=self.sleeps.append,
                     classify=classify)
        self.assertEqual(calls, [("[OnlyFans.com] A", "Clips and siterips")])
        self.assertEqual(self.store.cache()["topics"][0]["production"],
                         {"class": "amateur", "confidence": 0.8})

    def test_reuses_stored_production(self):
        main.refresh(FakeLab([row(1)]), self.store, sleep=self.sleeps.append,
                     classify=lambda t, c: {"class": "industrial", "confidence": None})
        calls = []
        main.refresh(FakeLab([row(1), row(2)]), self.store, sleep=self.sleeps.append,
                     classify=lambda t, c: calls.append(t) or {"class": "amateur", "confidence": None})
        self.assertEqual(calls, ["t2"])
        topics = {t["id"]: t for t in self.store.cache()["topics"]}
        self.assertEqual(topics[1]["production"]["class"], "industrial")
        self.assertEqual(topics[2]["production"]["class"], "amateur")

    def test_classifier_failure_leaves_topic_unclassified(self):
        def classify(title, category):
            raise OSError("openrouter down")

        main.refresh(FakeLab([row(1)]), self.store, sleep=self.sleeps.append, classify=classify)
        topics = self.store.cache()["topics"]
        self.assertEqual([t["id"] for t in topics], [1])
        self.assertNotIn("production", topics[0])

    def test_without_classifier_no_production(self):
        self.refresh(FakeLab([row(1)]))
        self.assertNotIn("production", self.store.cache()["topics"][0])
```

Add a new class after `FiltersTest` (at the end of the file, before any `if __name__` block):

```python
class MakeClassifier(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.dir.cleanup()

    def test_no_key_file_means_none(self):
        self.assertIsNone(main.make_classifier(os.path.join(self.dir.name, "missing")))

    def test_key_file_builds_classifier(self):
        path = os.path.join(self.dir.name, "key")
        with open(path, "w") as f:
            f.write("sk-key\n")
        fn = main.make_classifier(path, "other/model")
        self.assertEqual(fn.__self__.headers, {"Authorization": "Bearer sk-key"})
        self.assertEqual(fn.__self__.model, "other/model")
```

In `RunRefresh.test_run_refresh_passes_filter_file`, `run_refresh` now forwards `classify`. Make the stub accept it by replacing

```python
        main.refresh = lambda lab, store, exclude_file=None, filter_file=None: calls.append(filter_file)
```

with

```python
        main.refresh = lambda lab, store, exclude_file=None, filter_file=None, **kw: calls.append(filter_file)
```

and add after that test:

```python
    def test_run_refresh_passes_classifier(self):
        calls = []
        saved = main.drain_queue, main.refresh
        main.drain_queue = lambda *args: None
        main.refresh = lambda lab, store, classify=None, **kw: calls.append(classify)
        classify = object()
        try:
            main.run_refresh(None, None, "http://rpc", "/vault", classify=classify)
        finally:
            main.drain_queue, main.refresh = saved
        self.assertEqual(calls, [classify])
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd hosts/galactica/services/plab && python3 -m unittest -v test_main`
Expected: the new tests fail. They fail with `TypeError: refresh() got an unexpected keyword argument 'classify'` (or the same for `run_refresh`), and with `AttributeError: module 'main' has no attribute 'make_classifier'`.

- [ ] **Step 3: Implement**

In `main.py`:

1. Add `classify` under `import transmission` and `category` to the existing `from forums import FORUMS` line:

```python
import page
import parse
import transmission
from classify import MODEL, Classifier
from forums import FORUMS, category
```

2. Add a docstring line after the `Design:` line:

```
Production ranking: docs/superpowers/specs/2026-10-30-plab-production-ranking-design.md
```

3. Change the `refresh` signature to:

```python
def refresh(lab, store, forums=FORUMS, days=DAYS, limit=LIMIT, sleep=time.sleep,
            exclude_file=None, filter_file=None, classify=None):
```

4. In the topic loop, replace

```python
        names = [name for name, _ in filters if name in matched]
        topics.append({**row, "images": images, "filters": names,
                       "curated_reason": matched[names[0]] if names else None})
```

with

```python
        names = [name for name, _ in filters if name in matched]
        topic = {**row, "images": images, "filters": names,
                 "curated_reason": matched[names[0]] if names else None}
        # Judged once per release; an unclassified one ranks on seeders alone until retried.
        production = previous.get(row["id"], {}).get("production")
        if production is None and classify:
            try:
                production = classify(row["title"], category(row["forum"]))
            except Exception as e:  # noqa: BLE001 -- classification must never sink the refresh
                log(f"classify {row['id']}: {e}")
        if production:
            topic["production"] = production
        topics.append(topic)
```

5. Replace the final log line of `refresh` with:

```python
    log(f"refreshed: {len(topics)} topics ({sum(1 for t in topics if t['filters'])} curated, "
        f"{sum(1 for t in topics if 'production' in t)} classified)")
```

6. Replace `run_refresh` with:

```python
def run_refresh(lab, store, rpc_url, download_dir, exclude_file=None, filter_file=None, classify=None):
    """The `refresh` subcommand: drain the queue, then rebuild the list."""
    try:
        drain_queue(lab, store, rpc_url, download_dir)
    except LoginError:
        raise  # the session is gone; the list refresh would only fail the same way
    except Exception as e:  # noqa: BLE001 -- the list refresh must still run
        log(f"queue drain failed: {e}")
    refresh(lab, store, exclude_file=exclude_file, filter_file=filter_file, classify=classify)
```

7. Add after `run_refresh`:

```python
def make_classifier(key_file=None, model=None):
    """The production classifier for `refresh`, or None without an OpenRouter key."""
    key_file = key_file or os.environ.get("PLAB_OPENROUTER_KEY_FILE")
    if not key_file or not os.path.isfile(key_file):
        return None
    with open(key_file) as f:
        api_key = f.read().strip()
    return Classifier(api_key, model or os.environ.get("PLAB_JEV_MODEL") or MODEL).classify
```

8. In `main()`, replace the `refresh` branch's call with:

```python
        run_refresh(lab, store, os.environ["PLAB_TRANSMISSION_URL"], os.environ["PLAB_DOWNLOAD_DIR"],
                    os.environ.get("PLAB_EXCLUDE_FILE"), os.environ.get("PLAB_FILTER_FILE"),
                    make_classifier())
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd hosts/galactica/services/plab && python3 -m unittest`
Expected: OK, with every old and new test passing.

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/main.py hosts/galactica/services/plab/test_main.py
git commit -m "feat(galactica): plab classify each release's production style on refresh"
```

---

### Task 3: Rank and label cards by production

**Files:**
- Modify: `hosts/galactica/services/plab/page.py`. Add constants plus `score`, change the `_card` meta line, and sort in `render`.
- Test: `hosts/galactica/services/plab/test_page.py`

**Interfaces:**
- Consumes: topic dicts that may carry `"production": {"class": str, ...}`, from Task 2.
- Produces: `page.WEIGHT`, `page.LABEL` and `page.score(topic) -> float`.

- [ ] **Step 1: Write the failing tests**

Add `import re` to the top of `test_page.py`, then add to the `Render` class:

```python
    def ranked(self, *specs):
        topics = []
        for i, (seeders, cls) in enumerate(specs, start=1):
            t = {**TOPIC, "id": i, "title": f"t{i}", "seeders": seeders}
            if cls:
                t["production"] = {"class": cls, "confidence": None}
            topics.append(t)
        out = self.render(topics)
        return [int(i) for i in re.findall(r'<button class="add[^"]*" data-id="(\d+)"', out)]

    def test_ranked_by_weighted_seeders(self):
        # industrial 279 -> 69.75, amateur 100 -> 150, unclassified 90, artistic 80
        order = self.ranked((279, "industrial"), (100, "amateur"), (90, None), (80, "pro_artistic"))
        self.assertEqual(order, [2, 3, 4, 1])

    def test_ties_keep_cache_order(self):
        self.assertEqual(self.ranked((50, None), (50, "pro_artistic"), (50, None)), [1, 2, 3])

    def test_score(self):
        self.assertEqual(page.score({"seeders": 100}), 100)
        self.assertEqual(page.score({"seeders": 100, "production": {"class": "industrial"}}), 25)
        self.assertEqual(page.score({"seeders": 100, "production": {"class": "amateur"}}), 150)

    def test_production_label(self):
        for cls, label in (("amateur", "amateur"), ("pro_artistic", "artistic"), ("industrial", "industrial")):
            out = self.render([{**TOPIC, "production": {"class": cls, "confidence": None}}])
            self.assertIn(f'<span class="production">{label}</span>', out)

    def test_no_label_when_unclassified(self):
        self.assertNotIn('class="production"', self.render([TOPIC]))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd hosts/galactica/services/plab && python3 -m unittest -v test_page`
Expected: `test_ranked_by_weighted_seeders` and `test_production_label` FAIL, and `test_score` ERRORs with `AttributeError: module 'page' has no attribute 'score'`.

- [ ] **Step 3: Implement**

In `page.py`, add after `TOPIC_URL = ...`:

```python
# Seeders count for more or less by how the release was produced (classify.py), so
# gonzo-factory releases sink below amateur and artistic ones. Unclassified counts as 1.0.
WEIGHT = {"amateur": 1.5, "pro_artistic": 1.0, "industrial": 0.25}
LABEL = {"amateur": "amateur", "pro_artistic": "artistic", "industrial": "industrial"}


def _production(t):
    return (t.get("production") or {}).get("class")


def score(t):
    return t["seeders"] * WEIGHT.get(_production(t), 1.0)
```

In `_card`, replace the meta line

```python
            f'<div class="meta text-xs text-base-content/60">{size(t["size"])} · ▲ {t["seeders"]} ▼ {t["leechers"]} · {date}</div>'
```

with

```python
            f'<div class="meta text-xs text-base-content/60">{size(t["size"])} · ▲ {t["seeders"]} ▼ {t["leechers"]} · {date}{production}</div>'
```

and define `production` just before the `return` in `_card`:

```python
    cls = _production(t)
    production = f' · <span class="production">{LABEL[cls]}</span>' if cls in LABEL else ""
```

In `render`, replace

```python
    topics = cache["topics"]
```

with

```python
    # sorted() is stable with reverse=True too: equal scores keep the tracker's order.
    topics = sorted(cache["topics"], key=score, reverse=True)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd hosts/galactica/services/plab && python3 -m unittest`
Expected: OK. If an existing test assumed cache order with differing seeders, it now sees score order. Fix that test's expectation (seeders order), not the code.

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/page.py hosts/galactica/services/plab/test_page.py
git commit -m "feat(galactica): plab rank cards by production-weighted seeders"
```

---

### Task 4: Wire the key on galactica, deploy and audit

**Files:**
- Modify: `hosts/galactica/services/plab/default.nix`

**Interfaces:**
- Consumes: the `PLAB_OPENROUTER_KEY_FILE` and `PLAB_JEV_MODEL` environment variables read by `make_classifier`, from Task 2.

- [ ] **Step 1: Export the key path and own the secret**

In `default.nix`, in the `plab` script text, after the `PLAB_FILTER_FILE` export, add:

```nix
      # Jev ranks releases by production style; without the key, plab ranks on seeders alone.
      export PLAB_OPENROUTER_KEY_FILE="''${PLAB_OPENROUTER_KEY_FILE:-${secrets.openrouter-api-key.path}}"
```

After `sops.secrets.plab-filter.owner = vars.user;`, add the following. stash-identify declares the same owner; the equal values merge, and plab no longer depends on that file to read its key.

```nix
  sops.secrets.openrouter-api-key.owner = vars.user;
```

Extend the header comment's `# Design:` line with a second line:

```nix
# Production ranking: docs/superpowers/specs/2026-10-30-plab-production-ranking-design.md
```

`PLAB_JEV_MODEL` is deliberately not exported. The Python default `classify.MODEL` is the single place the model is named.

- [ ] **Step 2: Format and build**

Run: `cd /home/arosenfeld/Code/nixos && just fmt && just build galactica`
Expected: the build succeeds.

- [ ] **Step 3: Commit and push**

```bash
git add hosts/galactica/services/plab/default.nix
git commit -m "feat(galactica): plab reads the OpenRouter key for production ranking"
git push
```

- [ ] **Step 4: Deploy and classify the existing cache**

Run:

```bash
just deploy galactica
ssh galactica.bat-boa.ts.net 'sudo systemctl start plab-refresh; sudo journalctl -u plab-refresh -n 20 --no-pager'
```

Expected: the log ends with `refreshed: N topics (… curated, M classified)`, with M close to N. A few `classify <id>: …` lines are acceptable; those topics are retried on the next refresh.

- [ ] **Step 5: Audit the classifications**

Run:

```bash
ssh galactica.bat-boa.ts.net 'sudo python3 -c "
import json, re, collections
c = json.load(open(\"/var/lib/plab/cache.json\"))
by = collections.defaultdict(collections.Counter)
for t in c[\"topics\"]:
    m = re.match(r\"\s*\[([^\]]+)\]\", t[\"title\"])
    s = m.group(1).split(\"/\")[0].strip().lower() if m else \"(none)\"
    by[s][(t.get(\"production\") or {}).get(\"class\")] += 1
for s, n in sorted(by.items(), key=lambda kv: -sum(kv[1].values())):
    print(s, dict(n))
"'
```

Expected:
- legalporno.com, tushy*.com, woodmancastingx.com, familytherapyxxx.com and backroomcastingcouch.com are mostly `industrial`.
- x-art.com, sexart.com, erikalust.com, bellesa*, frolicme.com and vivthomas.com are mostly `pro_artistic`.
- onlyfans.com, manyvids.com and the `(none)` homemade titles are mostly `amateur`.

Report the table to the user. A studio class that is consistently wrong is the trigger for the spec's deferred override list. Do not tune the criteria inside this plan.
