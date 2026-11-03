# plab Alpine.js Client Architecture Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `plab`'s client-side reactivity from vanilla imperative DOM manipulation in `assets.py` to declarative Alpine.js components (`plabApp` and `plabCard`) while preserving server-rendered card HTML in `page.py`, state persistence, and offline asset vendoring.

**Architecture:** Pinned Alpine.js 3.14.8 is vendored via Nix into `PLAB_STATIC_DIR` and served via `/static/alpine.js`. The HTML template in `page.py` renders server-side markup with Alpine directives (`x-data`, `x-show`, `:class`, `x-text`, `x-model`, `@click`). `assets.py` registers two Alpine components on `alpine:init`: `plabApp` (manages filter state, hash/storage sync, gallery modal, and visit novelty) and `plabCard` (manages local card action button states, hover labels, and async Transmission requests).

**Tech Stack:** Python 3 (stdlib HTTP server & HTML renderer), Alpine.js v3.14.8, Tailwind CSS runtime, daisyUI v5, Nix.

**Spec:** `docs/superpowers/specs/2026-10-12-plab-alpinejs-design.md`

## Global Constraints

- Standalone Alpine.js core: no external plugins (`@alpinejs/persist` not used; persistence managed via `$watch` and `localStorage` in component lifecycle).
- Zero external CDN requests at runtime: all static assets fetched at Nix build time and served locally.
- Strict backwards compatibility for `localStorage` (`plab.filters`, `plab.seen`) and URL hash formatting (`#h24=1&couples=1&cat=...&tags=a,b`).
- Preserves all existing unit tests in `hosts/galactica/services/plab/`.

---

### Task 1: Static Asset Packaging & Serving

**Files:**
- Modify: `hosts/galactica/services/plab/test_main.py:335-368`
- Modify: `hosts/galactica/services/plab/main.py:265-272`
- Modify: `hosts/galactica/services/plab/default.nix:22-46`

**Interfaces:**
- Consumes: `pkgs.fetchurl` in `default.nix`, `STATIC` dict in `main.py`
- Produces: `/static/alpine.js` endpoint returning Alpine.js with Content-Type `text/javascript; charset=utf-8`

- [ ] **Step 1: Write the failing test for `alpine.js` static serving**

In `hosts/galactica/services/plab/test_main.py`, update `Static.setUp` to create `alpine.js` and update `test_allowed_names_with_types` to assert `alpine.js` is served:

```python
class Static(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        for name in ("daisyui.css", "themes.css", "tailwind.js", "alpine.js", "secret.txt"):
            with open(os.path.join(self.dir.name, name), "w") as f:
                f.write(name)

    def tearDown(self):
        self.dir.cleanup()

    def test_allowed_names_with_types(self):
        self.assertEqual(main.static_file(self.dir.name, "daisyui.css"), (b"daisyui.css", "text/css; charset=utf-8"))
        self.assertEqual(main.static_file(self.dir.name, "themes.css")[1], "text/css; charset=utf-8")
        self.assertEqual(main.static_file(self.dir.name, "tailwind.js"),
                         (b"tailwind.js", "text/javascript; charset=utf-8"))
        self.assertEqual(main.static_file(self.dir.name, "alpine.js"),
                         (b"alpine.js", "text/javascript; charset=utf-8"))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest test_main.Static.test_allowed_names_with_types -v`
Expected: FAIL because `main.STATIC` does not yet contain `"alpine.js"`.

- [ ] **Step 3: Update `main.py` and `default.nix`**

In `hosts/galactica/services/plab/main.py`:
```python
STATIC = {
    "daisyui.css": "text/css; charset=utf-8",
    "themes.css": "text/css; charset=utf-8",
    "tailwind.js": "text/javascript; charset=utf-8",
    "alpine.js": "text/javascript; charset=utf-8",
}
```

In `hosts/galactica/services/plab/default.nix`:
Add Alpine.js v3.14.8 to `static`:
```nix
    {
      name = "alpine.js";
      path = pkgs.fetchurl {
        url = "https://cdn.jsdelivr.net/npm/alpinejs@3.14.8/dist/cdn.min.js";
        hash = "sha256-tgDjY9mdlURNtUrL+y3v/smueSqpmgkim82geOW1VkM=";
      };
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest test_main.Static -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/main.py hosts/galactica/services/plab/default.nix hosts/galactica/services/plab/test_main.py
git commit -m "feat(plab): add alpine.js to static asset linkFarm and HTTP handler"
```

---

### Task 2: Alpine Component Registration in `assets.py`

**Files:**
- Modify: `hosts/galactica/services/plab/assets.py:1-178`
- Modify: `hosts/galactica/services/plab/test_page.py:221-257`

**Interfaces:**
- Consumes: Alpine globals (`document.addEventListener('alpine:init')`, `Alpine.data`)
- Produces: `plabApp` root data component and `plabCard` item data component defined in `assets.JS`

- [ ] **Step 1: Write unit tests in `test_page.py` for Alpine script contents**

In `hosts/galactica/services/plab/test_page.py`, update `FilterBar.test_filter_script_hooks`, `FilterBar.test_new_survives_reload_hooks`, and `Shell.test_queued_state_swaps_daisyui_classes` to assert Alpine component hooks:

```python
    def test_filter_script_hooks(self):
        script = self.render().split("<script>")[1]
        for hook in ("Alpine.data('plabApp'", "Alpine.data('plabCard'", "plab.filters", "h24",
                     "'new'", "'hide'", "'couples'", "replaceState", "location.hash", "'tags'"):
            self.assertIn(hook, script)

    def test_new_survives_reload_hooks(self):
        script = self.render().split("<script>")[1]
        for hook in ("plab.seen", "prev", "cur", "30 * 60 * 1000", "Array.isArray", "Object.hasOwn"):
            self.assertIn(hook, script)

    def test_queued_state_swaps_daisyui_classes(self):
        script = self.out.split("<script>")[1]
        self.assertIn("btnClass", script)
        self.assertIn("btnLabel", script)
        self.assertIn("'btn-warning queued'", script)
        self.assertIn("'Remove ✕'", script)
        self.assertIn(".add.queued:not(:disabled):hover", self.out.split("<style>")[1])
```

- [ ] **Step 2: Run tests to verify failure**

Run: `python3 -m unittest test_page.FilterBar.test_filter_script_hooks test_page.Shell.test_queued_state_swaps_daisyui_classes -v`
Expected: FAIL on missing `Alpine.data` definitions.

- [ ] **Step 3: Implement Alpine scripts in `assets.py`**

In `hosts/galactica/services/plab/assets.py`:
- Add `[x-cloak] { display: none !important; }` to `CSS`.
- Replace legacy DOM manipulation with `Alpine.data('plabApp', ...)` and `Alpine.data('plabCard', ...)` registered on `alpine:init`:
  - `plabApp`:
    - Handles filter state `st: { h24: false, new: false, hide: false, couples: false, cat: '', q: '', studio: '', tags: [] }`.
    - `cards: []`, `registerCard(card)` adds card to array.
    - `shownCount` getter: counts cards satisfying `isVisible(c)`.
    - `init()` runs `initSeen()`, `initFilters()`, and registers `$watch('st', () => this.saveFilters())`.
    - `initSeen()` evaluates `localStorage['plab.seen']` with 30m window, sets `newIds = new Set(next.prev)`, sets `newCount = count`.
    - `initFilters()`, `saveFilters()`, `fromHash(h)`, `toHash(s)` for `#...` and `localStorage['plab.filters']`.
    - `toggle(key)`, `toggleTag(tag)`, `clearFilters()`.
    - `modalImages: []`, `openGallery(images)`, `closeGallery()`.
  - `plabCard(cfg)`:
    - Holds `id`, `fresh`, `curated`, `cat`, `q`, `studio`, `tags`, `state: cfg.initialState || ''`, `loading: false`, `hoverQueued: false`, `error: ''`, `isNew: false`.
    - In `init()`: registers with parent `registerCard(this)` and sets `isNew = this.newIds ? this.newIds.has(String(this.id)) : false`.
    - Getters `btnLabel`, `btnClass`.
    - Async method `toggleAdd()` POSTing to `add/<id>` or `unqueue/<id>`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m unittest test_page.FilterBar.test_filter_script_hooks test_page.FilterBar.test_new_survives_reload_hooks test_page.Shell.test_queued_state_swaps_daisyui_classes -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/assets.py hosts/galactica/services/plab/test_page.py
git commit -m "feat(plab): implement plabApp and plabCard Alpine components in assets.py"
```

---

### Task 3: Template Integration & Declarative Directives in `page.py`

**Files:**
- Modify: `hosts/galactica/services/plab/page.py:1-140`
- Modify: `hosts/galactica/services/plab/test_page.py:1-352`

**Interfaces:**
- Consumes: `assets.CSS`, `assets.JS`
- Produces: Complete rendered HTML document in `page.render()` with Alpine directives attached to card, filter bar, header, and modal dialog.

- [ ] **Step 1: Write/update tests in `test_page.py` for Alpine directives**

Update tests in `test_page.py`:
- `Shell.test_theme_and_static_assets`: Check `<script defer src="static/alpine.js"></script>`.
- `Card.test_card_renders_curated_attribute_and_badge`: Card carries `x-data="plabCard({...})"`.
- `Render.test_new_badge_hooks`: `<span x-show="isNew" class="new badge ...">NEW</span>`.
- `FilterBar.test_toggles`: Check buttons have `@click="toggle('h24')"` and `:class="{ 'btn-primary': st.h24 }"`.
- `FilterBar.test_selected_state_toggles_btn_primary`: Assert `:class="{ 'btn-primary': st.tags.includes(` and `:class="{ 'btn-primary': st[`.
- `Shell.test_overlay_is_a_modal_dialog`: Modal dialog has `x-ref="modal"`.

- [ ] **Step 2: Run tests to verify failures**

Run: `python3 -m unittest test_page -v`
Expected: FAIL on template markup assertions.

- [ ] **Step 3: Update `page.py` rendering functions**

In `hosts/galactica/services/plab/page.py`:
1. `_card()`:
   - Compute JSON configuration for `plabCard`:
     ```python
     cfg = json.dumps({
         "id": t["id"],
         "fresh": fresh,
         "curated": curated,
         "cat": lab["category"],
         "q": lab["quality"] or "",
         "studio": lab["studio"] or "",
         "tags": lab["tags"],
         "initialState": state,
     })
     ```
   - Add `x-data="plabCard(%s)"` (with JSON escaping), `x-show="isVisible($data)"`, and `:class="{ 'is-new ring-2 ring-(--color-accent)': isNew }"`.
   - NEW badge rendered declaratively: `<span x-show="isNew" class="new badge badge-accent badge-lg font-bold absolute top-2 left-2 z-[1]">NEW</span>`.
   - Action button rendered with:
     ```html
     <button class="add btn btn-sm %(cls)s" :class="btnClass"
             :disabled="loading || state === 'added'"
             :title="state === 'queued' ? 'Click to remove from queue' : ''"
             @mouseenter="hoverQueued = (state === 'queued' && !loading)"
             @mouseleave="hoverQueued = false"
             @click="toggleAdd()">
       <span x-text="btnLabel">%(label)s</span>
     </button>
     <span class="err text-xs text-error" x-text="error"></span>
     ```
   - Thumbnail zoom calls `@click="openGallery(%(keys_json)s)"`.
2. `_filter_bar()`:
   - Toggle buttons have `:class="{ 'btn-primary': st.%(k)s }"` and `@click="toggle('%(k)s')"`.
   - Selects have `x-model="st.%(key)s"`.
   - Tag chips have `:class="{ 'btn-primary': st.tags.includes('%(tag)s') }"` and `@click="toggleTag('%(tag)s')"`.
   - Selected tags rendered with `<template x-for="t in st.tags" :key="t"><button type="button" class="btn btn-xs btn-primary" @click="toggleTag(t)" x-text="t + ' ×'"></button></template>`.
   - Tag input has `@keydown.enter.prevent="addTyped()"` and `@input="onTagInput()"`.
   - Result count has `x-text="'Showing ' + shownCount + ' of ' + cards.length"`.
   - Clear button has `@click="clearFilters()"`.
3. `render()`:
   - `<head>` adds `<script defer src="static/alpine.js"></script>`.
   - `<body>` has `x-data="plabApp"`.
   - Header has `<span x-show="newCount > 0" x-text="' · ' + newCount + ' new'"></span>`.
   - Modal dialog has `x-ref="modal" @click="closeGallery()"`. Inside `.modal-box`: `<template x-for="img in modalImages" :key="img"><img class="block mx-auto mb-3 max-w-full" loading="lazy" :src="'img/' + img"></template>`.
   - Script tag at end of body emits `assets.JS` registering components.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m unittest test_page -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add hosts/galactica/services/plab/page.py hosts/galactica/services/plab/test_page.py
git commit -m "feat(plab): update page template with declarative Alpine directives"
```

---

### Task 4: Full Test Suite Verification & Nix Evaluation

**Files:**
- Test all: `hosts/galactica/services/plab/`
- Verify: `hosts/galactica/services/plab/default.nix`

- [ ] **Step 1: Run complete plab test suite**

Run: `python3 -m unittest -v` in `hosts/galactica/services/plab/`
Expected: 154+ tests pass with zero failures and zero errors.

- [ ] **Step 2: Validate Nix derivation evaluation**

Run: `nix eval .#nixosConfigurations.galactica.config.environment.systemPackages`
Expected: Successful evaluation without syntax or evaluation errors.

- [ ] **Step 3: Commit any final test cleanups or documentation adjustments**

```bash
git status
```
(If any unstaged cleanups exist, commit them with a descriptive message).
