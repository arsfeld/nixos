# plab — Alpine.js Client Architecture Migration

**Host:** galactica · **URL:** `https://plab.arsfeld.one` · **Code:** `hosts/galactica/services/plab/`

## Goal

Migrate the client-side JavaScript of `plab` from ~160 lines of imperative DOM manipulation in `assets.py` to declarative, reactive Alpine.js components. The Python server-rendered HTML cards and layout in `page.py` remain the primary delivery mechanism, while Alpine.js directives (`x-data`, `x-show`, `:class`, `x-text`, `x-model`, `@click`) manage UI state: filter bar controls, card visibility, visit history / NEW badges, image preview modal, and asynchronous torrent addition/unqueue actions.

---

## 1. Static Asset Packaging & Delivery

### Nix Derivation (`hosts/galactica/services/plab/default.nix`)
Add Alpine.js (pinned stable v3.14.8) to the `static` `linkFarm` alongside `daisyui.css`, `themes.css`, and `tailwind.js`:
```nix
{
  name = "alpine.js";
  path = pkgs.fetchurl {
    url = "https://cdn.jsdelivr.net/npm/alpinejs@3.14.8/dist/cdn.min.js";
    hash = "sha256-tgDjY9mdlURNtUrL+y3v/smueSqpmgkim82geOW1VkM=";
  };
}
```

### Server Route (`hosts/galactica/services/plab/main.py`)
Add `"alpine.js"` to the `STATIC` allowlist dictionary with exact-match protection against directory traversal:
```python
STATIC = {
    "daisyui.css": "text/css; charset=utf-8",
    "themes.css": "text/css; charset=utf-8",
    "tailwind.js": "text/javascript; charset=utf-8",
    "alpine.js": "text/javascript; charset=utf-8",
}
```

### HTML Shell (`hosts/galactica/services/plab/page.py`)
In `<head>`, include `<script defer src="static/alpine.js"></script>` before the closing tag, and include `[x-cloak] { display: none !important; }` in `CSS`.

---

## 2. Alpine.js Components & State

Alpine components are registered via `Alpine.data` inside `document.addEventListener('alpine:init', ...)` in `assets.py`.

### 2.1 Root Application Component (`plabApp`)
Attached to `<body x-data="plabApp">`.

#### State Properties:
- `st`: Filter criteria object:
  - `h24` (bool): Uploaded within last 24h.
  - `new` (bool): New since previous visit (outside 30m window).
  - `hide` (bool): Hide added and queued releases.
  - `couples` (bool): Filter by curated indie & couples content.
  - `cat` (string): Selected category name (or `""` for All).
  - `q` (string): Selected quality/resolution (or `""` for All).
  - `studio` (string): Selected studio name (or `""` for All).
  - `tags` (array of strings): Selected tags (ANDed).
- `cards`: Array of registered card component references.
- `newIds`: Set of topic IDs determined to be NEW on this visit.
- `newCount`: Total count of NEW releases displayed in the header.
- `modalImages`: Array of image keys currently displayed in the gallery modal.

#### Methods & Lifecycle:
- `init()`:
  1. `initSeen()`: Evaluates `localStorage['plab.seen']` with a 30-minute window. Updates `{ prev, cur, at }` and populates `newIds` and `newCount`.
  2. `initFilters()`: Hydrates `st` from `location.hash` if present; falls back to `localStorage['plab.filters']`.
  3. Sets up `$watch('st', () => this.saveFilters())` to synchronize state with URL hash and `localStorage`.
- `registerCard(card)`: Adds card instance to `this.cards`.
- `isVisible(card)`: Evaluates filter conditions against card metadata:
  ```javascript
  return (!this.st.h24 || card.fresh)
    && (!this.st.new || card.isNew)
    && (!this.st.hide || !card.state)
    && (!this.st.couples || card.curated)
    && (!this.st.cat || card.cat === this.st.cat)
    && (!this.st.q || card.q === this.st.q)
    && (!this.st.studio || card.studio === this.st.studio)
    && this.st.tags.every(t => card.tags.includes(t));
  ```
- `shownCount`: Getter returning count of registered cards matching `isVisible(card)`.
- `toggle(key)`: Toggles boolean filter flags (`h24`, `new`, `hide`, `couples`).
- `toggleTag(tag)`: Adds or removes tag from `st.tags`.
- `clearFilters()`: Resets `st` to empty state.
- `openGallery(images)`: Sets `this.modalImages = images; this.$refs.modal.showModal();`.
- `closeGallery()`: Calls `this.$refs.modal.close();` and clears `this.modalImages`.

---

### 2.2 Card Component (`plabCard`)
Attached to each `.card` element: `x-data="plabCard({...})"`:

#### Parameters:
- `id`: Topic ID (number).
- `fresh`: Uploaded within last 24h (bool).
- `curated`: Curated couples content (bool).
- `cat`: Category name (string).
- `q`: Quality (string).
- `studio`: Studio name (string).
- `tags`: Tag list (array of strings).
- `initialState`: Initial server-rendered state (`"added"`, `"queued"`, or `""`).

#### State Properties:
- `state`: Current state (`"added"`, `"queued"`, or `""`).
- `loading`: Boolean indicating in-flight async request.
- `hoverQueued`: Boolean tracking mouse hover over queued button.
- `error`: Inline error message string.
- `isNew`: Boolean indicating release is new since last visit.

#### Methods & Getters:
- `init()`:
  - Registers card with root: `this.registerCard(this)`.
  - Determines novelty: `this.isNew = this.newIds.has(String(this.id))`.
- `btnLabel`: Computed property:
  - If `loading`: `"Adding…"` (or `"Removing…"` if currently queued).
  - If `state === 'added'`: `"Added ✓"`.
  - If `state === 'queued'`: `hoverQueued ? "Remove ✕" : "Queued ⏳"`.
  - Default: `error ? "Retry" : "Add to Vault"`.
- `btnClass`: Computed property:
  - If `state === 'queued'`: `"btn-warning queued"`.
  - Default: `"btn-primary"`.
- `async toggleAdd()`:
  - If `loading || state === 'added'`, return early.
  - Sets `loading = true; error = ''`.
  - POSTs to `unqueue/<id>` if queued, or `add/<id>` if unadded.
  - On success:
    - If unqueued: `state = ''; error = ''`.
    - If response has `queued: true`: `state = 'queued'; error = data.message`.
    - Else: `state = 'added'`.
  - On error: Restores interactivity, displays error in inline `<span class="err" x-text="error">`.
  - Sets `loading = false; hoverQueued = false`.

---

## 3. DOM & Template Changes (`page.py`)

### 3.1 Card Markup (`_card`)
- Server-rendered HTML carries initial button text, attributes, and classes for graceful rendering before Alpine hydrates.
- Card container:
  ```html
  <div class="card bg-base-200 shadow-sm overflow-hidden"
       x-data="plabCard({ id: %(id)d, fresh: %(fresh)s, curated: %(curated)s, cat: %(cat)s, q: %(q)s, studio: %(studio)s, tags: %(tags)s, initialState: %(state)s })"
       x-show="isVisible($data)"
       :class="{ 'is-new ring-2 ring-(--color-accent)': isNew }">
  ```
- NEW Badge:
  ```html
  <span x-show="isNew" class="new badge badge-accent badge-lg font-bold absolute top-2 left-2 z-[1]">NEW</span>
  ```
- Action Button:
  ```html
  <button class="add btn btn-sm %(btn_class)s"
          :class="btnClass"
          :disabled="loading || state === 'added'"
          :title="state === 'queued' ? 'Click to remove from queue' : ''"
          @mouseenter="hoverQueued = (state === 'queued' && !loading)"
          @mouseleave="hoverQueued = false"
          @click="toggleAdd()">
    <span x-text="btnLabel">%(btn_label)s</span>
  </button>
  <span class="err text-xs text-error" x-text="error">%(err_text)s</span>
  ```
- Thumbnail click:
  ```html
  <img class="thumb w-full h-full object-cover cursor-zoom-in"
       loading="lazy"
       src="img/%(thumb_key)s"
       @click="openGallery(%(images_json)s)" alt="">
  ```

### 3.2 Filter Bar Markup (`_filter_bar`)
- Toggles: `<button type="button" class="btn btn-sm" :class="{ 'btn-primary': st.h24 }" @click="toggle('h24')">Last 24h</button>` (and similarly for `new`, `couples`, `hide`).
- Dropdowns: `<select class="select select-sm w-auto max-w-full" x-model="st.cat" ...>`.
- Chips: `<button type="button" class="btn btn-xs" :class="{ 'btn-primary': st.tags.includes(t) }" @click="toggleTag(t)">...`.
- Selected tag chips:
  ```html
  <template x-for="t in st.tags" :key="t">
    <button type="button" class="btn btn-xs btn-primary" @click="toggleTag(t)" x-text="t + ' ×'"></button>
  </template>
  ```
- Result count: `<span class="ml-auto text-sm text-base-content/60" x-text="'Showing ' + shownCount + ' of ' + cards.length">Showing %(count)d of %(count)d</span>`.
- Clear button: `<button type="button" class="btn btn-ghost btn-sm" @click="clearFilters()">Clear</button>`.

### 3.3 Modal Dialog (`render`)
```html
<dialog x-ref="modal" class="modal" @click="closeGallery()">
  <div class="modal-box w-11/12 max-w-5xl p-2 cursor-zoom-out" @click.stop="closeGallery()">
    <template x-for="img in modalImages" :key="img">
      <img class="block mx-auto mb-3 max-w-full" loading="lazy" :src="'img/' + img">
    </template>
  </div>
  <form method="dialog" class="modal-backdrop"><button>close</button></form>
</dialog>
```

---

## 4. Testing & Verification

1. **Unit Tests in `test_main.py`**:
   - `Static.test_allowed_names_with_types` includes `alpine.js` with `text/javascript; charset=utf-8`.
2. **Unit Tests in `test_page.py`**:
   - Updates assertions to verify presence of `static/alpine.js` script tag in `<head>`.
   - Asserts `x-data="plabApp"` and `x-data="plabCard(...)"` attributes and parameters in rendered cards.
   - Asserts Alpine directives on buttons, badges, filter toggles, and modal dialog.
   - Tests `assets.py` script content for `Alpine.data`, persistence hooks (`plab.filters`, `plab.seen`), and hash handling.
3. **Automated Verification**:
   - Execute `python3 -m unittest -v` across all test suites in `hosts/galactica/services/plab/`.
   - Verify Nix derivation parsing via `nix eval`.
