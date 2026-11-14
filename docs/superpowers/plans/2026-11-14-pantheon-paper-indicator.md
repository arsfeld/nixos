# pantheon-paper indicator and settings page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make pantheon-paper configurable from Pantheon: live GSettings, a D-Bus interface for session state, a Wingpanel indicator and a Switchboard plug.

**Architecture:** A new schema `io.github.arsfeld.paper` that the plugin follows live; a session-bus interface `io.github.arsfeld.Paper` exported by the plugin for what only Gala knows; an indicator (GTK 3) and a plug (GTK 4) that write the schema and talk to the interface. GLib-only shared code (`src/common/`) holds presets, rules and accelerator logic for all three.

**Tech Stack:** Vala, meson, GLib/GIO, libgee, Mutter 46/48 + Gala, wingpanel 8 + granite 6 (GTK 3), switchboard-3 + granite-7 (GTK 4), Nix, Debian packaging.

**Spec:** `docs/superpowers/specs/2026-11-14-pantheon-paper-indicator-design.md`

## Global Constraints

- Two repos. Plugin, indicator, plug, schema, Debian, CI: `~/Code/pantheon-paper` (commit style `feat: …` / `fix: …`). Nix package, module, just recipes, CLAUDE.md: `~/Code/nixos` (conventional commits, scope `modules`). Both commit straight to master; no branches.
- Never test the plugin by logging in with it; use the headless Gala (`just pantheon::paper-run`, run from the nixos repo's justfile against the plugin checkout). Never put the literal headless command line in your own shell command (`paper-stop` pkills it).
- Build and test inside `just pantheon::paper-shell` from the plugin checkout: `meson setup build; ninja -C build && meson test -C build`.
- Must build against Mutter 46 (elementary OS 8) and 48 (NixOS). Any Mutter call that differs goes in `src/Compat.vala`.
- `new Settings (id)` on a missing schema aborts Gala = ends the session. Every schema lookup in the plugin goes through `SettingsSchemaSource.lookup` first, as `Keys` does.
- Schema id `io.github.arsfeld.paper`, path `/io/github/arsfeld/paper/`. Keys and defaults exactly as the spec's table: `enabled` b true; `gap` i 8 range 0–48; `width-presets` ad `[0.3333333333, 0.5, 0.6666666667]`; `default-width` d 0.5; `animate` b true; `app-rules` a(sbdb) `[]`.
- `width-presets` valid iff 2–6 entries, each in [0.1, 1.0], strictly increasing.
- D-Bus: name and interface `io.github.arsfeld.Paper`, object `/io/github/arsfeld/Paper`; `WorkspaceTiled` b rw, `FocusedFloating` b rw, `FocusedApp` (ss) r, `RunningApps() → a(ss)`.
- The keybindings schema `io.github.arsfeld.paper.keybindings` is not changed.
- `settings://paper`, `settings://paper/rules`, `settings://paper/shortcuts`; plug category Personal, title "Tiling".
- The indicator's no-plugin text: "Tiling plugin not running — log out and back in".

## Review Focus

- **A hand-written invalid `width-presets`** (`[]`, unsorted, `[0.05]`): the plugin must keep tiling on the defaults and log once, not crash or divide by zero. Test in Task 1 (`/presets/invalid_falls_back`) and Task 3's demo step `bad-presets`.
- **Shrinking `width-presets` while columns use a high index**: columns clamp to the last preset; `cycle-width` still wraps. Test in Task 2 (`/strip/presets_shrink_clamps`).
- **Turning tiling off while a window is parked off-screen, then on again**: the parked window ends fully on screen, and re-enabling restores left-to-right order without losing windows. Demo steps in Task 4 (`off`, `on`).
- **The popover taking focus**: `FocusedFloating` / `FocusedApp` must refer to the last normal window, not Wingpanel. Task 5 measures it in the headless Gala and its unit test pins the rule (`focus_tracker` ignores non-normal windows).
- **Gala restarting under a running indicator**: the indicator greys out, then recovers when the name reappears. Task 7 model test `/indicator/name_vanishes_and_returns`.

---

### Task 1: Shared GLib-only code (`src/common/`)

**Files:**
- Create: `src/common/meson.build`, `src/common/Presets.vala`, `src/common/Rules.vala`, `src/common/Accels.vala`
- Create: `tests/test_common.vala`
- Modify: `meson.build` (define `common_sources` before `subdir('src/core')`, add to `core_sources`), `tests/meson.build` (add `'common'`)

**Interfaces:**
- Produces:
  - `Paper.DEFAULT_PRESETS : double[] = {1.0/3.0, 0.5, 2.0/3.0}`
  - `bool Paper.presets_valid (double[] p)`
  - `double[] Paper.presets_or_default (double[] p)` — returns `p` if valid, else a copy of `DEFAULT_PRESETS`
  - `int Paper.nearest_preset (double[] p, double fraction)` — index of the closest entry, ties to the lower index
  - `class Paper.AppRule : Object { string app_id; bool float_; double width; bool own_column; bool is_default (); }`
  - `Gee.ArrayList<AppRule> Paper.rules_from_variant (Variant v)` (type `a(sbdb)`), `Variant Paper.rules_to_variant (Gee.List<AppRule> rules)` (drops `is_default ()` rules)
  - `AppRule? Paper.match_rule (Gee.List<AppRule> rules, string? gtk_id, string? sandboxed_id, string? wm_class)` — case-insensitive, first match wins, null/empty ids never match
  - `string? Paper.accel_normalize (string accel)` — same as `norm()` in `tools/keys-check.py` (aliases ctrl/primary→control, mod1→alt, mod4→super; sorted mods + lowercased key joined by `+`; null when no key)
  - `class Paper.AccelOwner : Object { string schema; string key; }`
  - `Gee.ArrayList<AccelOwner> Paper.accel_clashes (string accel, Gee.Map<string, Gee.List<AccelOwner>> owners, string own_schema, string own_key)` — owners of the same normalized accel other than `(own_schema, own_key)`

- [ ] **Step 1: Write the failing tests** in `tests/test_common.vala` (`Test.add_func`, as `test_strip.vala` does):
  - `/presets/valid`: `presets_valid({0.25, 0.5})` true; `{0.5}` false (too few); 7 entries false; `{0.5, 0.5}` false; `{0.6, 0.4}` false; `{0.05, 0.5}` false; `{0.5, 1.0}` true.
  - `/presets/invalid_falls_back`: `presets_or_default({})` equals `DEFAULT_PRESETS`; `presets_or_default({0.25, 0.75})` equals `{0.25, 0.75}`.
  - `/presets/nearest`: with `DEFAULT_PRESETS`, `0.5` → 1, `0.9` → 2, `0.0` → 0, `0.41666` → 0 (tie to lower).
  - `/rules/roundtrip`: two rules through `rules_to_variant`/`rules_from_variant` keep every field; a rule with float false, width 0, own_column false is dropped.
  - `/rules/match`: rule `"Firefox"` matches wm_class `"firefox"`; rule `"org.gnome.Calculator"` matches gtk_id; no rule matches when every id is null or `""`; with two matching rules the first is returned.
  - `/accels/normalize`: `"<Super><Shift>Left"` and `"<Shift><Mod4>left"` both → `"shift+super+left"`; `"<Primary>q"` → `"control+q"`; `"<Super>"` → null.
  - `/accels/clashes`: owners map `{"super+left": [(wm, switch-left), (paper, focus-left)]}`; `accel_clashes ("<Super>Left", owners, "paper", "focus-left")` returns just `(wm, switch-left)`; for `"<Super>j"` returns empty.

- [ ] **Step 2: Run, expect a build failure** (`ninja -C build`: undefined `presets_valid` etc.).

- [ ] **Step 3: Implement the three files** with the signatures above. `Accels.vala` ports `norm()` exactly; keep the alias table identical to `tools/keys-check.py`.

- [ ] **Step 4: Run** `ninja -C build && meson test -C build` — all tests, old and new, PASS.

- [ ] **Step 5: Commit** — `feat: shared presets, app rules and accelerator helpers`.

---

### Task 2: Core takes its gap, presets and solo rule from parameters

**Files:**
- Modify: `src/core/Types.vala` (remove `GAP`; keep `SLIVER`, `ANIM_MS`), `src/core/Strip.vala` (drop `enum Preset`), `src/core/Layout.vala`, `src/core/Tiling.vala`, `src/core/Drop.vala`
- Create: `src/core/Params.vala`
- Modify callers so it compiles: `src/Controller.vala` (`Slot.preset` becomes `int`), `src/Mouse.vala`, `src/Demo.vala` (`GAP` → `c.params.gap`)
- Test: `tests/test_strip.vala`, `tests/test_layout.vala`, `tests/test_tiling.vala`, `tests/test_drop.vala`

**Interfaces:**
- Consumes: `presets_or_default`, `nearest_preset` (Task 1).
- Produces:
  - `class Paper.Params : Object { int gap = 8; double[] presets = DEFAULT_PRESETS; int default_preset = 1; int pixels (int preset, int work_width); int clamp_preset (int preset); }` — `pixels` = `round (work_width * presets[clamp_preset (preset)]) - gap`
  - `interface Paper.SoloCheck : Object { bool is_solo (uint64 id); }` and `class Paper.NoSolo` (always false)
  - `Strip` gains `public Params params` and `public SoloCheck solo` (constructor `Strip (Params params = new Params (), SoloCheck solo = new NoSolo ())`); `Column.preset` is `int`; `Column.with (uint64 id, int preset)`; new columns use `params.default_preset`.
  - `layout`, `scroll_to_focus`, `center_focus`, `pan` read `s.params.gap` instead of `GAP` (signatures unchanged).
  - `WindowFacts.rule_float : bool`; `should_tile` also requires `!rule_float`.
  - `Strip.insert_after_focused (uint64 id, int preset = -1)` — `-1` means `params.default_preset`; same optional parameter on `insert_at` and `append`.
  - `uint64[] Paper.order_by_x (uint64[] ids, int[] xs)` — ids sorted by x, stable.

- [ ] **Step 1: Update existing tests** to the new types (`Preset.HALF` → `1`, `TWO_THIRDS` → `2`, `THIRD` → `0`) and **add**:
  - `/strip/presets_shrink_clamps`: column at preset 2; set `s.params.presets = {0.3, 0.6}`; `params.pixels (col.preset, 1000)` is `600 - 8`; `cycle_width` takes it to 0 (wraps from the clamped last).
  - `/strip/custom_presets_cycle`: presets `{0.25, 0.5, 0.75, 1.0}`; `cycle_width` from 0 visits 1, 2, 3, 0.
  - `/strip/slurp_skips_solo`: solo set {2}; strip `[1][2][3]` focused on 1; `slurp` leaves `"1|2|3"`. Solo set {1}: `slurp` from 1 leaves `"1|2|3"`.
  - `/strip/drop_into_solo_becomes_column`: solo {3}; `move_to (1, INTO_COLUMN column of 3)` gives a new column beside 3 (`"2|3|1"` or `"2|1|3"`: assert 1 and 3 are in different columns). Same when the dragged window is the solo one.
  - `/layout/gap_param`: `params.gap = 20`; two columns are 20 px apart.
  - `/tiling/rule_float`: facts otherwise tiling, `rule_float = true` → `should_tile` false.
  - `/strip/order_by_x`: `order_by_x ({1,2,3}, {500, -200, 100})` → `{2, 3, 1}`.

- [ ] **Step 2: Run, expect build failures.**

- [ ] **Step 3: Implement.** `cycle_width`'s free-width snap iterates `params.presets` indices. `slurp` returns early when the next column's top window or any window of the focused column is solo. `move_to` with `INTO_COLUMN` turns into `NEW_COLUMN` at `t.column + 1` when the dragged window or any window in the target column is solo.

- [ ] **Step 4: Run** `ninja -C build && meson test -C build` — PASS. Then `just pantheon::paper-run build PAPER_DEMO=4` and `PAPER_DEMO_KEYS=1 PAPER_DEMO=4`: the `paper-demo: at` lines match a run of the parent commit (same frames). `just pantheon::paper-stop`.

- [ ] **Step 5: Commit** — `refactor: gap, width presets and solo rule are parameters of the core`.

---

### Task 3: The schema and live settings in the plugin

**Files:**
- Create: `data/io.github.arsfeld.paper.gschema.xml`, `src/Config.vala`
- Modify: `meson.build` (install the schema), `src/meson.build`, `src/Plugin.vala`, `src/Controller.vala`, `src/Applier.vala` (animate), `src/Demo.vala` (new step list)
- Modify (nixos repo): `just/pantheon.just` `paper-run` — also `cp -f "$build/../data/io.github.arsfeld.paper.gschema.xml" /tmp/paper-gala-schemas/`

**Interfaces:**
- Consumes: Task 1 helpers; `Params`, `SoloCheck`, `WindowFacts.rule_float` (Task 2).
- Produces:
  - `class Paper.Config : Object { const string SCHEMA = "io.github.arsfeld.paper"; bool available; bool enabled; int gap; double[] presets; double default_width; bool animate; Gee.List<AppRule> rules; signal void changed (string key); void set_enabled (bool v); Settings? settings; }` — without the schema, `available` is false, values are the defaults, setters are no-ops.
  - `Controller (Gala.WindowManager wm, Config config)`; `Controller.params : Params` (kept in sync with config); `Controller.rule_for (Meta.Window w) : AppRule?`; `Controller` implements `SoloCheck`.
  - Demo: `PAPER_DEMO_SETTINGS=1` step list `gap-24`, `presets-quarters`, `bad-presets`, `default-width-third`, `rule-float`, `rule-width-full`, `rule-solo`, `settle`, each writing `config.settings` inside Gala (the headless Gala uses the memory backend, so outside `gsettings set` cannot reach it).

- [ ] **Step 1: Write the schema** with the keys of Global Constraints, each with a `<summary>`.

- [ ] **Step 2: Implement `Config`** (lookup-first; `presets` via `presets_or_default`, logging a warning once per invalid value; `rules` via `rules_from_variant`).

- [ ] **Step 3: Wire the controller:** `Params.gap/presets/default_preset (= nearest_preset (presets, default_width))` from config; `facts_for` sets `rule_float`; on `Reason.CREATED` a rule width of `1` makes the new column `full`, another non-zero width uses `nearest_preset`; strips get `this` as `SoloCheck` (`is_solo` = rule with `own_column`). On `config.changed`: refresh params, `reevaluate` every tracked window for `app-rules` (rules can float or unfloat), then `relayout ()`. `animations_enabled ()` returns `config.animate && enable-animations`.

- [ ] **Step 4: Build and unit-test** — `ninja -C build && meson test -C build` PASS.

- [ ] **Step 5: Headless check.** `just pantheon::paper-run build PAPER_DEMO=4 PAPER_DEMO_SETTINGS=1`, then read `/tmp/paper-gala.log`:
  - after `gap-24`, adjacent visible columns are 24 px apart;
  - after `presets-quarters` (`[0.25, 0.5, 0.75]`), a `cycle-width` step yields 0.25-based widths (`round(1920*0.25)-24`);
  - `bad-presets` (`[0.9, 0.1]`) logs one warning and the frames match the default presets; Gala still running;
  - after `default-width-third` and a newly opened demo window (the step opens one with `PAPER_DEMO_CMD`), its column is `round(1920/3)-gap` wide;
  - `rule-float` (rule for the demo app id) takes demo windows out of the strip; `rule-width-full` opens the next one full width; `rule-solo` then a `slurp` leaves columns unchanged.
  The list ends with `rebind` (sets `focus-left` to `['<Super>h']` in the keybindings schema, in-process) followed by four `settle` steps. Once the log shows `at <i> rebind`, run `just pantheon::paper-inject key:super+h`: the next `at` line must show focus one column to the left. If it does not, Mutter does not follow keybinding settings live: make `Keys` connect to `settings.changed` and re-add the changed binding (`remove_keybinding` + `add_keybinding`), and re-check. `just pantheon::paper-stop`.

- [ ] **Step 6: Commit** (plugin) — `feat: live settings in io.github.arsfeld.paper: gap, width presets, default width, animation, app rules`; (nixos) — `chore(modules): paper-run installs pantheon-paper's settings schema`.

---

### Task 4: Global and per-workspace off

**Files:**
- Modify: `src/Controller.vala`, `src/Demo.vala`

**Interfaces:**
- Consumes: `Config.enabled` (Task 3), `order_by_x` (Task 2).
- Produces:
  - `bool Controller.workspace_tiled (Meta.Workspace ws)`; `void Controller.set_workspace_tiled (Meta.Workspace ws, bool on)`; `signal void Controller.state_changed ()` (emitted on either switch and on active-workspace change)
  - Demo `PAPER_DEMO_TOGGLE=1` step list: `off`, `on`, `ws-off`, `open-on-ws-off`, `ws-on`, `settle`.

- [ ] **Step 1: Implement** `release (Strip s)`: for every placement of the current layout, parked windows are moved (user-op `move_resize_frame`) just inside the work area on their side; non-parked windows are not touched; the strip is dropped. `adopt (Meta.Workspace ws)`: tracked windows of `ws` passing `should_tile`, ordered with `order_by_x` by frame x, appended. `enabled` false → release every strip and make `reevaluate` place nothing; true → adopt every workspace. Per-workspace: a `Gee.HashSet<Meta.Workspace> off`, pruned in `prune_workspaces`; `reevaluate` places nothing on a workspace in it.

- [ ] **Step 2: Build, unit-test** — PASS.

- [ ] **Step 3: Headless check** with `PAPER_DEMO=4 PAPER_DEMO_TOGGLE=1` (four demo windows at half width on 1920 px, so at least one is parked first): after `off`, every window's frame lies fully within `0..1920` and non-parked frames equal the frames at `open`; after `on`, the column order equals the left-to-right order at `off`, four windows tiled; after `ws-off` + `open-on-ws-off` the new window is not in the strip; after `ws-on` it is. Gala still running at the end.

- [ ] **Step 4: Commit** — `feat: tiling can be switched off for the session or one workspace`.

---

### Task 5: The D-Bus interface

**Files:**
- Create: `src/Bus.vala`, `src/core/Focus.vala`, `tests/test_focus.vala`
- Modify: `src/Plugin.vala`, `src/Controller.vala`, `src/meson.build`, `src/core/meson.build`, `tests/meson.build`

**Interfaces:**
- Consumes: `Controller.workspace_tiled`, `set_workspace_tiled`, `state_changed` (Task 4), `toggle_float`, `is_floating`.
- Produces:
  - `class Paper.FocusTracker : Object { uint64 last; void focused (uint64 id, bool normal); void forget (uint64 id); }` (pure, in core) — `last` changes only for normal windows; `forget` of `last` resets it to 0.
  - `[DBus (name = "io.github.arsfeld.Paper")] class Paper.Bus : Object` with properties `WorkspaceTiled`, `FocusedFloating`, `FocusedApp` and method `RunningApps`, as in Global Constraints; `Bus.own (Controller c)`, `Bus.unown ()` called from `Plugin.initialize`/`destroy`.
  - `Controller.focused_window () : Meta.Window?` (via `FocusTracker.last`), `Controller.app_of (Meta.Window w, out string id, out string name)` — id: gtk app id, else sandboxed id, else WM_CLASS; name: the matching `.desktop` name via `GLib.DesktopAppInfo` when found, else the id.

- [ ] **Step 1: Failing test** `/focus/ignores_non_normal`: `focused (5, true); focused (9, false)` → `last == 5`; `forget (5)` → 0; `focused (7, true)` → 7.

- [ ] **Step 2: Run** — fails to build. **Step 3: Implement** `FocusTracker`, then `Bus` (emits `PropertiesChanged` from `state_changed` and focus changes; writing `FocusedFloating` calls `toggle_float` on `focused_window ()` only when the value differs).

- [ ] **Step 4: Unit tests PASS.**

- [ ] **Step 5: Headless check** with `PAPER_DEMO=4 PAPER_DEMO_IDLE=1`, using `DBUS_SESSION_BUS_ADDRESS=$(cat /tmp/paper-gala.bus)`:
  - `gdbus introspect --session --dest io.github.arsfeld.Paper --object-path /io/github/arsfeld/Paper` lists the four members;
  - `gdbus call … --method org.freedesktop.DBus.Properties.Set io.github.arsfeld.Paper WorkspaceTiled '<false>'` → the next `paper-demo: at` line shows no strip; set `<true>` → tiled again;
  - set `FocusedFloating '<true>'` → the focused window leaves the strip;
  - `RunningApps` returns one entry for the demo app.
  - **Focus question:** with `paper-inject`, click a point outside any window and, separately, open a GTK popover-type window (`tests/demo-window.py` with a new `--popup` flag that opens a `Gtk.Window` of type hint `POPUP_MENU`); record whether `display.focus_window` changes and confirm `FocusedApp` still names the demo window. Note the result in the plugin's README.

- [ ] **Step 6: Commit** — `feat: io.github.arsfeld.Paper on the session bus for the panel indicator`.

---

### Task 6: Meson options

**Files:**
- Create: `meson_options.txt`
- Modify: `meson.build`

**Interfaces:**
- Produces: options `plugin`, `indicator`, `plug` (boolean, default `true`); `subdir('indicator')` / `subdir('plug')` guarded by them; the "No supported mutter" `error()` only when `plugin` is on.

- [ ] **Step 1:** Add the options and guards (the `indicator/` and `plug/` dirs come in Tasks 7–8; until then guard with `if get_option('indicator') and fs.is_dir('indicator')`, removed in Task 8).
- [ ] **Step 2: Verify** `meson setup b2 -Dplugin=false && ninja -C b2 && meson test -C b2` builds and runs the core and common tests without Mutter; the default build still produces `libgala-paper.so`.
- [ ] **Step 3: Commit** — `build: plugin, indicator and plug are meson options`.

---

### Task 7: The Wingpanel indicator

**Files:**
- Create: `indicator/meson.build`, `indicator/Indicator.vala`, `indicator/Model.vala`, `src/common/PaperProxy.vala` (in `common_sources`, so the plug uses the same file), `indicator/Popover.vala`, `indicator/ShortcutsView.vala`, `data/icons/` (three symbolic icons: `paper-tiling-symbolic`, `paper-tiling-workspace-off-symbolic`, `paper-tiling-off-symbolic`), `tests/test_indicator_model.vala`
- Modify: `tests/meson.build` (the model test, only when `indicator` is on)

**Interfaces:**
- Consumes: the schemas (Task 3), the D-Bus interface (Task 5), `Actions.NAMES` order (copy the list; the indicator must not link the plugin).
- Produces:
  - `[DBus (name = "io.github.arsfeld.Paper")] interface Paper.PaperProxy` mirroring Task 5's members.
  - `class Paper.IndicatorModel : Object { bool connected; bool enabled; bool workspace_tiled; bool focused_floating; string focused_name; string focused_id; string icon_name; void set_proxy (PaperProxy? p); }` — `icon_name`: off if `!enabled`, workspace-off if `connected && !workspace_tiled`, else tiling. Settings writes go through a `Settings` passed in, so tests can use a memory backend.
  - `Wingpanel.Indicator` subclass with code name `"paper"`; `get_widgets ()` returns a `Gtk.Image` bound to `icon_name`; popover rows as listed in the spec, in that order, with `Granite.accel_to_string` for the shortcuts page; "Tiling Settings…" opens `settings://paper`; "Add rule for "<app>"…" opens `settings://paper/rules?add=<app id>` (URI-escaped).

- [ ] **Step 1: Failing model tests** (`GSETTINGS_BACKEND=memory`, `GSETTINGS_SCHEMA_DIR` = the build's compiled `data/`):
  - `/indicator/icon_states`: enabled + connected + tiled → `paper-tiling-symbolic`; `workspace_tiled = false` → workspace-off; `enabled = false` → off regardless.
  - `/indicator/name_vanishes_and_returns`: `set_proxy (fake)` → `connected`; `set_proxy (null)` → `!connected`, `icon_name` falls back to the enabled/off state; `set_proxy (fake)` again → `connected`, values re-read.
  - `/indicator/switch_writes_settings`: toggling `enabled` on the model writes `enabled` in the schema.
- [ ] **Step 2: Run** — fails. **Step 3: Implement** model, proxy watching (`Bus.watch_name`), popover, shortcuts page, indicator; the live switches' `sensitive` follows `connected`, with the exact text from Global Constraints when not.
- [ ] **Step 4: Tests PASS**, and the whole project builds with the indicator on (`ninja -C build`).
- [ ] **Step 5: Commit** — `feat: a Wingpanel indicator for tiling`.

---

### Task 8: The Switchboard plug

**Files:**
- Create: `plug/meson.build`, `plug/Plug.vala`, `plug/LayoutPage.vala`, `plug/RulesPage.vala`, `plug/ShortcutsPage.vala`, `plug/RulesModel.vala`, `plug/KeyOwners.vala`, `tests/test_plug_models.vala`
- Modify: `meson.build` (drop the Task 6 `fs.is_dir` guards), `tests/meson.build`

**Interfaces:**
- Consumes: Task 1 helpers; the schemas; `RunningApps` through `Paper.PaperProxy` (`src/common/PaperProxy.vala`, Task 7).
- Produces:
  - `Switchboard.Plug` subclass, `code_name "io.github.arsfeld.paper"`, category `PERSONAL`, display name "Tiling", supported settings `paper`, `paper/rules`, `paper/shortcuts`; `search_callback` points at the pages. `search ()` returns the page names.
  - `class Paper.RulesModel : Object { Gee.List<AppRule> rules; void add (string app_id); void remove (int i); void update (int i, AppRule r); }` writing `app-rules` through `rules_to_variant` on every change.
  - `Gee.Map<string, Gee.List<AccelOwner>> Paper.collect_key_owners (SettingsSchemaSource src)` — every non-relocatable schema's `as` keys, same value filter as `tools/keys-check.py` (contains `<` or longer than one character).
  - `RulesPage` handles `paper/rules?add=<id>` by adding (or scrolling to) that rule.

- [ ] **Step 1: Failing model tests:**
  - `/plug/rules_add_remove_writes`: `add ("org.gnome.Calculator")` then `update` with `float_ = true` → `app-rules` holds one rule `("org.gnome.Calculator", true, 0, false)`; `update` back to defaults → `app-rules` is `[]`.
  - `/plug/key_owners`: with a test schema dir holding a schema with `as` key `x = ['<Super>Left']`, `collect_key_owners` maps `"super+left"` to that schema/key, and `accel_clashes` against the plugin's own key finds it.
  - `/plug/presets_edit_refuses_invalid`: the Layout page's preset editor model refuses adding `0.05` and a duplicate, and keeps the list sorted.
- [ ] **Step 2: Run** — fails. **Step 3: Implement** the models and three pages: Layout (switch, `Gtk.SpinButton` 0–48 for gap, preset list with add/remove in percent, default-width dropdown of presets, animate switch); Rules (rows with float switch, width dropdown "Default"/each preset/"Full width", own-column switch, delete; Add popover with `RunningApps` entries and a text entry); Shortcuts (row per action, click to capture with `Gtk.EventControllerKey`, Escape cancels, BackSpace clears, clash → `Granite.MessageDialog` naming the other `schema key`, Replace removes the accel from that key's array, Cancel restores).
- [ ] **Step 4: Tests PASS; full build PASS.** Run the plug on the live session (a separate process, safe): after Task 10's deploy, or now with `io.elementary.settings` from a dev shell pointed at the build's plug dir via `SWITCHBOARD_PLUGS_PATH` if switchboard-3 honours it — otherwise leave it to Task 10's manual check.
- [ ] **Step 5: Commit** — `feat: a Tiling page in System Settings: layout, app rules and shortcuts`.

---

### Task 9: Debian package and CI

**Files:**
- Modify: `debian/control` (Build-Depends `libwingpanel-dev`, `libswitchboard-3-dev`, `libgtk-3-dev`, `libgtk-4-dev`, `libgranite-dev`, `libgranite-7-dev`; Depends adds `wingpanel`, `switchboard`; description mentions the indicator and the Tiling settings page), `ci/check-install.sh`

**Interfaces:**
- Consumes: the meson install paths from Tasks 7–8 (from `pkg-config --variable=indicatorsdir wingpanel` and `--variable=plugsdir switchboard-3`, the conventional elementary variables).

- [ ] **Step 1:** Update control; extend `check-install.sh` with: `test -f /usr/lib/x86_64-linux-gnu/wingpanel/libpaper.so`, `test -f /usr/lib/x86_64-linux-gnu/switchboard-3/personal/libpaper.so` (use the actual installed file names from the build), `ldd` on both with no `not found`, and `gsettings list-keys io.github.arsfeld.paper | grep -qx width-presets`.
- [ ] **Step 2: Verify locally** with the command in `ci/build-deb.sh`'s header followed by `ci/check-install.sh` in the same container: both exit 0.
- [ ] **Step 3: Commit** — `build: the Debian package ships the indicator and the settings page`.

---

### Task 10: Nix package, module, docs

**Files (nixos repo):**
- Modify: `packages/pantheon-paper/package.nix` (new `rev`/`hash`; buildInputs add `gtk3 gtk4 pantheon.granite pantheon.granite7 pantheon.wingpanel pantheon.switchboard`; update the header comment), `modules/desktop/pantheon-paper.nix` (`extraWingpanelIndicators = [paper]; extraSwitchboardPlugs = [paper];`; header comment mentions the indicator and the plug), `CLAUDE.md` ("Pantheon tiling": the indicator, the plug, the schema, the D-Bus name, the memory-backend note for testing settings in the headless Gala)
- Modify (plugin repo): `README.md` (settings table, indicator, plug, the focus finding from Task 5)

- [ ] **Step 1: Push the plugin repo** — outward-facing (CI publishes a `.deb` release on master): confirm with the user before `git push`.
- [ ] **Step 2:** Set `rev` to the pushed commit and fix `hash` (build once with `lib.fakeHash`, copy the reported hash).
- [ ] **Step 3: Verify** `nix develop -c just build raider` succeeds (one host only, niced; never cylon-link), and `just pantheon::paper-keys-check raider` passes.
- [ ] **Step 4: Commit** (nixos) — `feat(modules): pantheon-paper panel indicator and Tiling settings page`; (plugin) — `docs: settings, indicator and settings page`.
- [ ] **Step 5: Hand to the user**: deploy (`nix develop -c just test raider` or `deploy`) is theirs to call, then a logout/login. Manual checks there: the icon's three states, each popover switch, Tiling Settings… opens the page, a rule added from the popover appears on the Rules page, a rebind on the Shortcuts page works without logging out, a clash prompt appears for `<Super>s`.
