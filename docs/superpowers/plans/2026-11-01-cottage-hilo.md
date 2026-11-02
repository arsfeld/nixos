# Cottage Hilo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Control the cottage's Hilo account from galactica's Home Assistant beside home's, and heat the cottage automatically from phone proximity.

**Architecture:** A second build of dvd-dev's Hilo component, renamed to domain `hilo_cottage`, runs alongside the original. A small patch shared by both builds keeps each one's unknown-power accounting off the other account's entities. A new host-local module on galactica declares `input_select.cottage_mode` and the automations that move it between `away`, `preheat` and `comfort` and push setpoints to the cottage thermostats.

**Tech Stack:** Nix (`buildHomeAssistantComponent`, flake-parts checks), Home Assistant YAML config generated from Nix, Jinja templates, Hilo custom component (dvd-dev/hilo 2026.10.3, python-hilo 2026.10.1).

**Spec:** `docs/superpowers/specs/2026-11-01-cottage-hilo-design.md`

## Global Constraints

- Commit straight to `master`. No branches, no worktrees.
- Conventional commits: `<type>(<scope>): <subject>`, scope `galactica` for everything here. Never mention Claude.
- Run `just fmt` (alejandra) before every commit that touches `.nix`.
- A new file is invisible to `nix build` until it is `git add`ed (`git add -N` is enough).
- Evaluate or build one host at a time, niced. Never build or evaluate `cylon-link`.
- Every `substituteInPlace` uses `--replace-fail`.
- Setpoints: comfort `20` °C, away `10` °C. Timeouts: pre-heat 45 min, departure 30 min, safety net 12 h.
- Challenge phases that block setpoint changes: `pre_heat`, `reduction`, `on`, `recovery`. A challenge has ended when the sensor goes to `off`.
- Entity IDs fixed by this plan: `input_select.cottage_mode`, `zone.cottage`, `sensor.cottage_nearest_distance`, `sensor.cottage_nearest_direction_of_travel`, `sensor.defi_hilo_cottage`, `person.alexandre_rosenfeld`. Notify action: `notify.mobile_app_alexandres_iphone`.
- Coordinates of the cottage never enter the repo. Ring distances in km may.
- Steps marked **(user)** need the user in the Home Assistant UI. Stop and ask them; do not try to script around them.

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `packages/home-assistant-hilo/unknown-power-own-entry.patch` | create | Keeps unknown-power accounting and smart-meter search off another Hilo entry's entities |
| `packages/home-assistant-hilo/package.nix` | modify | Applies the patch to home's build |
| `packages/home-assistant-hilo-cottage/package.nix` | create | Renamed copy, domain `hilo_cottage`, reusing home's `version`/`src`/`patches` |
| `modules/flake/checks.nix` | modify | `hilo-cottage-rename` check on the built copy |
| `modules/hosts/galactica/services/home-assistant.nix` | modify | Adds the copy to `customComponents` |
| `modules/hosts/galactica/services/home-assistant-cottage.nix` | create | Cottage mode helper, rings, automations |

---

### Task 1: Unknown-power patch on home's Hilo build

**Files:**
- Create: `packages/home-assistant-hilo/unknown-power-own-entry.patch`
- Modify: `packages/home-assistant-hilo/package.nix`

**Interfaces:**
- Produces: the derivation attribute `pkgs.home-assistant-hilo.patches` (a list containing the patch). Task 2 inherits it. The patched `custom_components/hilo/__init__.py` contains a method `Hilo._owned_by_other_hilo(self, entity_id: str) -> bool`.

- [ ] **Step 1: Confirm the patch is absent today**

Run:
```bash
cd ~/Code/nixos
out=$(nice nix build --no-link --print-out-paths .#nixosConfigurations.galactica.pkgs.home-assistant-hilo)
grep -c _owned_by_other_hilo "$out/custom_components/hilo/__init__.py"
```
Expected: prints `0` (grep exits 1). This is the failing state.

- [ ] **Step 2: Write the patch**

Create `packages/home-assistant-hilo/unknown-power-own-entry.patch` with exactly:

```diff
--- a/custom_components/hilo/__init__.py
+++ b/custom_components/hilo/__init__.py
@@ -396,8 +396,8 @@
         """Initialize."""
         self._api = api
         self._hass = hass
-        self.find_meter(self._hass)
         self.entry = entry
+        self.find_meter(self._hass)
         self.devices: Devices = Devices(api)
         self.graphql_helper: GraphQlHelper = GraphQlHelper(api, self.devices)
         self.challenge_id = 0
@@ -983,6 +983,21 @@
         if self.track_unknown_sources:
             self.handle_unknown_power()
 
+    def _owned_by_other_hilo(self, entity_id: str) -> bool:
+        """Whether another Hilo config entry owns this entity.
+
+        Local patch: hilo and hilo_cottage run side by side, one per Hilo
+        account. Each must leave the other's entities out of its unknown-power
+        accounting and its smart meter search, or home's tracker subtracts the
+        cottage's power from home's meter.
+        """
+        entry = er.async_get(self._hass).async_get(entity_id)
+        return (
+            entry is not None
+            and entry.platform in ("hilo", "hilo_cottage")
+            and entry.config_entry_id != self.entry.entry_id
+        )
+
     def find_meter(self, hass):
         """Find the smart meter entity in Home Assistant."""
         entity_registry_dict = {}
@@ -994,6 +1009,8 @@
 
         # ic-dev21: Get names of all entities
         for entity_id, entity_entry in registry.entities.items():
+            if self._owned_by_other_hilo(entity_id):
+                continue
             entity_registry_dict[entity_id] = {
                 "name": entity_entry.entity_id,
             }
@@ -1166,6 +1183,8 @@
         unknown_source_tracker = "sensor.unknown_source_tracker_power"
         for state in self._hass.states.async_all():
             entity = state.entity_id
+            if self._owned_by_other_hilo(entity):
+                continue
             if entity.endswith("hilo_rate_current"):
                 continue
 
```

This was generated with `diff -ru` against the pinned 2026.10.3 source and checked with `patch -p1 --dry-run` during planning. `er` is already imported in that file (`entity_registry as er`). Why each hunk exists:
- The reorder is needed because `__init__` calls `find_meter` before it sets `self.entry`, and the new filter reads `self.entry`.
- The filter skips only entities owned by *another* Hilo entry. Upstream deliberately counts every other `*_power` entity (a metered plug) as known, and that must not change for home.

- [ ] **Step 3: Apply it in the package**

In `packages/home-assistant-hilo/package.nix`, add after the `src = …;` block:

```nix
  # Two Hilo accounts (home, and the cottage through home-assistant-hilo-cottage)
  # share one Home Assistant. Upstream's unknown-power tracker subtracts every
  # *_power entity from the smart meter, so without this home's tracker would
  # also subtract the cottage's thermostats and meter. See
  # docs/superpowers/specs/2026-11-01-cottage-hilo-design.md.
  patches = [./unknown-power-own-entry.patch];
```

Also extend the header comment's last sentence to read: `Bump version and python-hilo (overlays/python-packages.nix) together; a bump that moves the patched code fails to apply, and home-assistant-hilo-cottage follows this version.`

- [ ] **Step 4: Verify the patch is applied and the file still parses**

Run:
```bash
git add -N packages/home-assistant-hilo/unknown-power-own-entry.patch
out=$(nice nix build --no-link --print-out-paths .#nixosConfigurations.galactica.pkgs.home-assistant-hilo)
grep -c _owned_by_other_hilo "$out/custom_components/hilo/__init__.py"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$out/custom_components/hilo/__init__.py" && echo parses
```
Expected: `3` (definition plus two calls), then `parses`.

- [ ] **Step 5: Commit**

```bash
just fmt
git add packages/home-assistant-hilo/
git commit -m "fix(galactica): keep hilo unknown-power accounting to its own account"
```

---

### Task 2: The `hilo_cottage` copy and its flake check

**Files:**
- Modify: `modules/flake/checks.nix` (add a check after `heating-policy-test`)
- Create: `packages/home-assistant-hilo-cottage/package.nix`

**Interfaces:**
- Consumes: `pkgs.home-assistant-hilo` with attributes `version`, `src`, `patches`, `meta` (Task 1).
- Produces: `pkgs.home-assistant-hilo-cottage`, installing `custom_components/hilo_cottage/` with `DOMAIN = "hilo_cottage"`. Its challenge-sensor consumers read `sensor.defi_hilo_cottage`. Check name: `checks.x86_64-linux.hilo-cottage-rename`.

- [ ] **Step 1: Write the failing check**

In `modules/flake/checks.nix`, directly after the `heating-policy-test = …;` attribute, add:

```nix
        # The cottage's Hilo account runs as a renamed copy of the component
        # (packages/home-assistant-hilo-cottage). A rename that misses a spot
        # leaves the copy reading home's entities or state file, so assert
        # every one on the built output.
        hilo-cottage-rename = let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          c = "${self.nixosConfigurations.galactica.pkgs.home-assistant-hilo-cottage}/custom_components/hilo_cottage";
        in
          pkgs.runCommand "hilo-cottage-rename" {} ''
            has() { grep -qF -- "$2" "${c}/$1" || { echo "missing in $1: $2"; exit 1; }; }
            lacks() { if grep -qF -- "$2" "${c}/$1"; then echo "still in $1: $2"; exit 1; fi; }
            has const.py 'DOMAIN = "hilo_cottage"'
            has manifest.json '"domain": "hilo_cottage"'
            has manifest.json '"name": "Hilo Cottage"'
            has __init__.py 'hilo_cottage_state.yaml'
            lacks __init__.py '"hilo_state.yaml"'
            for name in "Defi Hilo" "Recompenses Hilo" "Notifications Hilo" "Outdoor Weather Hilo"; do
              has sensor.py "\"$name Cottage\""
            done
            lacks climate.py '"sensor.defi_hilo"'
            lacks __init__.py 'states.get("sensor.defi_hilo")'
            has __init__.py '_owned_by_other_hilo'
            touch $out
          '';
```

`lacks __init__.py 'states.get("sensor.defi_hilo")'` targets only `high_times`. The gateway rename map (`"sensor.hilo_gateway_defi_hilo": "sensor.defi_hilo"`) stays on purpose: it only renames the copy's own legacy entities, and skips any target ID that already exists.

- [ ] **Step 2: Run it to see it fail**

Run: `nice nix build --no-link .#checks.x86_64-linux.hilo-cottage-rename`
Expected: an evaluation error saying attribute `home-assistant-hilo-cottage` is missing.

- [ ] **Step 3: Write the package**

Create `packages/home-assistant-hilo-cottage/package.nix`:

```nix
# Hilo, a second time, for the cottage's Hilo account.
#
# dvd-dev's component allows one config entry per Home Assistant, and home
# and the cottage are separate Hilo accounts. This builds the same source as
# domain hilo_cottage, so both run in galactica's Home Assistant. Version,
# source and patches come from home-assistant-hilo: bump that one only.
# Design: docs/superpowers/specs/2026-11-01-cottage-hilo-design.md
#
# Every substitution fails the build if upstream moves its target, rather than
# shipping a copy that half-reads home's entities. The flake check
# hilo-cottage-rename asserts the result.
{pkgs, ...}: let
  hilo = pkgs.home-assistant-hilo;
  dir = "custom_components/hilo_cottage";
in
  pkgs.buildHomeAssistantComponent {
    owner = "dvd-dev";
    domain = "hilo_cottage";
    inherit (hilo) version src patches;

    # Patches apply to custom_components/hilo first; the rename runs after.
    postPatch = ''
      mv custom_components/hilo ${dir}

      substituteInPlace ${dir}/const.py \
        --replace-fail 'DOMAIN = "hilo"' 'DOMAIN = "hilo_cottage"'

      substituteInPlace ${dir}/manifest.json \
        --replace-fail '"domain": "hilo"' '"domain": "hilo_cottage"' \
        --replace-fail '"name": "Hilo"' '"name": "Hilo Cottage"'

      # Per-account Firebase and Android registration: never shared.
      substituteInPlace ${dir}/__init__.py \
        --replace-fail '"hilo_state.yaml"' '"hilo_cottage_state.yaml"' \
        --replace-fail 'states.get("sensor.defi_hilo")' 'states.get("sensor.defi_hilo_cottage")'

      substituteInPlace ${dir}/climate.py \
        --replace-fail '"sensor.defi_hilo"' '"sensor.defi_hilo_cottage"'

      substituteInPlace ${dir}/sensor.py \
        --replace-fail '"Defi Hilo"' '"Defi Hilo Cottage"' \
        --replace-fail '"Recompenses Hilo"' '"Recompenses Hilo Cottage"' \
        --replace-fail '"Notifications Hilo"' '"Notifications Hilo Cottage"' \
        --replace-fail '"Outdoor Weather Hilo"' '"Outdoor Weather Hilo Cottage"'
    '';

    dependencies = [pkgs.home-assistant.python3Packages.python-hilo];

    meta =
      hilo.meta
      // {
        description = "Hilo (Hydro-Québec) integration for Home Assistant, as domain hilo_cottage";
      };
  }
```

- [ ] **Step 4: Run the check to see it pass**

Run:
```bash
git add -N packages/home-assistant-hilo-cottage/package.nix
nice nix build --no-link -L .#checks.x86_64-linux.hilo-cottage-rename
```
Expected: builds with no `missing in`/`still in` lines.

If `buildHomeAssistantComponent` rejects the build because its manifest check compares `domain` with the directory, read the error. The `mv` plus the manifest substitution should already satisfy it. Do not loosen any `--replace-fail`.

- [ ] **Step 5: Commit**

```bash
just fmt
git add packages/home-assistant-hilo-cottage/ modules/flake/checks.nix
git commit -m "feat(galactica): hilo_cottage, a renamed copy of the Hilo component"
```

---

### Task 3: Ship both components to galactica and prove home is unaffected

**Files:**
- Modify: `modules/hosts/galactica/services/home-assistant.nix` (the `customComponents` list and the header comment)

**Interfaces:**
- Consumes: `pkgs.home-assistant-hilo-cottage` (Task 2), the patched `pkgs.home-assistant-hilo` (Task 1).
- Produces: a deployed galactica where "Hilo Cottage" can be added in the UI. Task 4 depends on that deploy.

- [ ] **Step 1: Record the tracker baseline before anything changes**

Run:
```bash
ssh galactica.bat-boa.ts.net "sudo nix shell nixpkgs#sqlite -c sqlite3 -readonly /var/lib/hass/home-assistant_v2.db \"
  SELECT datetime(s.last_updated_ts,'unixepoch','localtime'), m.entity_id, s.state
  FROM states s JOIN states_meta m USING(metadata_id)
  WHERE m.entity_id IN ('sensor.unknown_source_tracker_power','sensor.meter00_power')
    AND s.last_updated_ts > strftime('%s','now','-2 hours')
  ORDER BY s.last_updated_ts DESC LIMIT 20;\""
```
Expected: recent rows for both entities. Keep the output; Step 6 and Task 4 compare against it. The tracker should be the meter minus home's Hilo device power, so it is normally well above 0 when the heat pump runs.

- [ ] **Step 2: Add the copy to Home Assistant**

In `modules/hosts/galactica/services/home-assistant.nix`, in `customComponents`, directly under `pkgs.home-assistant-hilo # Hydro-Québec Hilo`, add:

```nix
          pkgs.home-assistant-hilo-cottage # The cottage's Hilo account (domain hilo_cottage)
```

In the header comment, change the line `# - Custom components for Tuya Local, Alarmo, Hilo, Eufy Security (eufy-sdk)` to `# - Custom components for Tuya Local, Alarmo, Hilo (home, and the cottage as hilo_cottage), Eufy Security (eufy-sdk)`.

- [ ] **Step 3: Build galactica**

Run: `nice nix build --no-link .#nixosConfigurations.galactica.config.system.build.toplevel`
Expected: success.

- [ ] **Step 4: Confirm the home heating checks still pass**

Run: `nice nix build --no-link .#checks.x86_64-linux.heating-policy-test`
Expected: success. Home's automations are untouched by this task, so a failure here means something unrelated broke. Stop and investigate.

- [ ] **Step 5: Commit, push and deploy**

```bash
just fmt
git add modules/hosts/galactica/services/home-assistant.nix
git commit -m "feat(galactica): ship hilo_cottage to home assistant"
git push origin master
just deploy galactica
```
Expected: the deploy activates galactica without failed units. Then run `ssh galactica.bat-boa.ts.net systemctl is-active home-assistant`, which should print `active`.

- [ ] **Step 6: Check home's tracker survived the patch**

Wait 10 minutes after Home Assistant starts, then rerun the Step 1 query.
Expected: the tracker and meter keep reporting, and the tracker's relation to the meter looks like the baseline (same order of magnitude, not stuck at 0). Also check the log:

```bash
ssh galactica.bat-boa.ts.net "journalctl -u home-assistant --since '-15 min' | grep -iE 'hilo.*(error|traceback)' | head -20"
```
Expected: no new Hilo errors. Errors that were already in the baseline log before the deploy don't count.

---

### Task 4: Cottage account, zone and proximity setup, and live verification

**Files:** none. This task records values that Task 5 needs.

**Interfaces:**
- Consumes: deployed galactica (Task 3).
- Produces, for Task 5:
  - `thermostats`: the list of cottage `climate.*` entity IDs
  - confirmation that `sensor.defi_hilo_cottage`, `sensor.cottage_nearest_distance` (in km) and `sensor.cottage_nearest_direction_of_travel` exist
  - `outerKm`, `innerKm`, `departKm` as integers

- [ ] **Step 1 (user): Add the cottage account**

Ask the user to go to Settings → Devices & services → Add integration → "Hilo Cottage", log in with the **cottage's** Hilo account, and leave every option at its default: energy meters off, unknown-source tracking off, challenge lock off.

- [ ] **Step 2 (user): Create the zone and the Proximity entry**

Ask the user to:
1. Settings → Areas, labels & zones → Zones → Add zone, named `Cottage`, placed on the cottage, radius 150 m. Its entity ID must be `zone.cottage`.
2. Settings → Devices & services → Add integration → Proximity: name `Cottage`, zone `Cottage`, tracked `person.alexandre_rosenfeld`, tolerance `1000` m. The tolerance keeps GPS jitter from flipping the direction to `away_from` mid-drive.

- [ ] **Step 3: Read the new entities from the registry**

Run:
```bash
ssh galactica.bat-boa.ts.net 'sudo python3 -c "
import json
r = json.load(open(\"/var/lib/hass/.storage/core.entity_registry\"))[\"data\"][\"entities\"]
for e in r:
    if e[\"platform\"] == \"hilo_cottage\" and e[\"entity_id\"].split(\".\")[0] in (\"climate\", \"sensor\"):
        print(e[\"entity_id\"], e[\"unique_id\"])
    if e[\"entity_id\"].startswith((\"sensor.cottage_nearest\", \"zone.cottage\")):
        print(e[\"entity_id\"], e[\"platform\"])
"'
```
Expected:
- one `climate.*` per cottage thermostat
- a challenge sensor whose unique ID ends in `-defi_hilo`
- `sensor.cottage_nearest_distance` and `sensor.cottage_nearest_direction_of_travel`

Write down the `climate.*` IDs for Task 5. If any of them collide in a confusing way with home's (`climate.office_2` and the like), ask the user whether to rename them in the UI to `climate.cottage_<room>` first, and use the final IDs.

- [ ] **Step 4 (user, if needed): Pin the challenge sensor's ID**

If the challenge sensor from Step 3 is not exactly `sensor.defi_hilo_cottage`, ask the user to open it in Settings → Entities and set its entity ID to `sensor.defi_hilo_cottage`. Re-run Step 3 to confirm.

- [ ] **Step 5: Confirm the distance is in km**

Run:
```bash
ssh galactica.bat-boa.ts.net "sudo nix shell nixpkgs#sqlite -c sqlite3 -readonly /var/lib/hass/home-assistant_v2.db \"
  SELECT s.state, a.shared_attrs FROM states s
  JOIN states_meta m USING(metadata_id) LEFT JOIN state_attributes a USING(attributes_id)
  WHERE m.entity_id='sensor.cottage_nearest_distance' ORDER BY s.last_updated_ts DESC LIMIT 1;\""
```
Expected: `unit_of_measurement` is `km`. If it is `m`, ask the user to change the sensor's display unit to km in its entity settings (the automation compares in km), and re-run.

- [ ] **Step 6: Compute the rings**

The Proximity distance is straight-line, so the rings come from coordinates rather than from driving. Joliette is 46.0218 N, 73.4404 W (town centre). Run:

```bash
ssh galactica.bat-boa.ts.net 'sudo python3 -c "
import json, math
cfg = json.load(open(\"/var/lib/hass/.storage/core.config\"))[\"data\"]
zones = json.load(open(\"/var/lib/hass/.storage/zone\"))[\"data\"][\"items\"]
cot = next(z for z in zones if z[\"name\"] == \"Cottage\")
def km(a, b, c, d):
    p = math.pi / 180
    h = math.sin((c - a) * p / 2) ** 2 + math.cos(a * p) * math.cos(c * p) * math.sin((d - b) * p / 2) ** 2
    return 2 * 6371 * math.asin(math.sqrt(h))
home = km(cfg[\"latitude\"], cfg[\"longitude\"], cot[\"latitude\"], cot[\"longitude\"])
jol = km(46.0218, -73.4404, cot[\"latitude\"], cot[\"longitude\"])
print(\"home->cottage %.1f km, joliette->cottage %.1f km\" % (home, jol))
print(\"outerKm = %d; innerKm = %d; departKm = %d;\" % (round(home) - 5, round(jol) - 5, round(jol) + 5))
"'
```
Expected: one line of distances, then a line of three integers with `innerKm < departKm < outerKm`. Only the integers go into the repo; the coordinates never do. If `departKm >= outerKm` (Joliette not between the two), stop and raise it with the user: the ring design assumes Joliette sits between home and the cottage.

- [ ] **Step 7: Confirm home's tracker ignores the cottage**

Rerun the query from Task 3 Step 1, and list the cottage's power entities:

```bash
ssh galactica.bat-boa.ts.net 'sudo python3 -c "
import json
r = json.load(open(\"/var/lib/hass/.storage/core.entity_registry\"))[\"data\"][\"entities\"]
print([e[\"entity_id\"] for e in r if e[\"platform\"] == \"hilo_cottage\" and e[\"entity_id\"].endswith(\"_power\")])
"'
```
Expected:
- the cottage has `*_power` entities, so the test isn't vacuous
- home's `sensor.unknown_source_tracker_power` still tracks `sensor.meter00_power` as in the baseline, and did not drop when the cottage was added
- no `unknown_source_tracker` entity belongs to `hilo_cottage`

If the tracker dropped, the patch is not taking effect. Stop and debug before Task 5.

---

### Task 5: Cottage heating automations

**Files:**
- Create: `modules/hosts/galactica/services/home-assistant-cottage.nix`

**Interfaces:**
- Consumes: the values from Task 4 (`thermostats`, `outerKm`, `innerKm`, `departKm`). Entity IDs are listed under Global Constraints.
- Produces: `input_select.cottage_mode` (`away`/`preheat`/`comfort`) and `services.home-assistant.config."automation cottage"` (six automations).

- [ ] **Step 1: Write the module**

Create `modules/hosts/galactica/services/home-assistant-cottage.nix`. Use the three integers printed by Task 4 Step 6 for `outerKm`, `innerKm` and `departKm`, and the climate IDs from Task 4 Step 3 for `thermostats`. Those are the only edits to the code below.

```nix
# Cottage heating: hold the cottage at 10 °C while it is empty, heat it to
# 20 °C from the moment someone drives toward it, and drop back after everyone
# leaves. Its thermostats come from hilo_cottage
# (packages/home-assistant-hilo-cottage), a renamed copy of home's Hilo.
# Design: docs/superpowers/specs/2026-11-01-cottage-hilo-design.md
#
# Set up once in the UI:
#   zone.cottage            the cottage, radius 150 m. Its coordinates stay out
#                           of this repo.
#   Proximity "Cottage"     zone.cottage, tracking person.alexandre_rosenfeld,
#                           tolerance 1000 m (GPS jitter would otherwise flip
#                           the direction mid-drive). Provides
#                           sensor.cottage_nearest_distance (km) and
#                           sensor.cottage_nearest_direction_of_travel.
#   Hilo Cottage            the cottage's Hilo account, options at defaults,
#                           its challenge sensor's ID set to
#                           sensor.defi_hilo_cottage (the ID the component's
#                           challenge lock and tariff check read).
#
# Joliette sits halfway along the drive and is visited from both ends, so it
# lies between innerKm and departKm. A trip home -> Joliette only pre-heats,
# then is cancelled; an errand cottage -> Joliette never counts as leaving.
#
#   home ──────────── Joliette ──────────── cottage
#        outerKm
#                   departKm
#                              innerKm
#
# Timeouts are checked on a clock as well as on triggers, so a restart (which
# drops a pending `for:`) delays them at most one tick rather than losing them.
{
  configurations.nixos.galactica.module = {lib, ...}: let
    # Straight-line km to zone.cottage, from the zone coordinates.
    outerKm = OUTER_FROM_TASK_4; # home, less 5: a drive from home has begun
    innerKm = INNER_FROM_TASK_4; # Joliette, less 5: past Joliette, really coming
    departKm = DEPART_FROM_TASK_4; # Joliette, plus 5: past Joliette, really gone

    preheatTimeoutMin = 45;
    departureDelayMin = 30;
    safetyNetHours = 12;
    comfort = 20;
    away = 10;

    thermostats = THERMOSTATS_FROM_TASK_4;

    mode = "input_select.cottage_mode";
    distance = "sensor.cottage_nearest_distance";
    direction = "sensor.cottage_nearest_direction_of_travel";
    defi = "sensor.defi_hilo_cottage";

    n = toString;
    within = km: "(is_number(states('${distance}')) and states('${distance}') | float < ${n km})";
    beyond = km: "(is_number(states('${distance}')) and states('${distance}') | float > ${n km})";
    occupied = "(states('zone.cottage') | int(0) > 0)";
    challenge = "states('${defi}') in ['pre_heat', 'reduction', 'on', 'recovery']";

    select = option: {
      action = "input_select.select_option";
      target.entity_id = mode;
      data.option = option;
    };
    notify = message: {
      action = "notify.mobile_app_alexandres_iphone";
      data = {
        title = "Cottage";
        inherit message;
      };
    };
    isMode = m: {
      condition = "state";
      entity_id = mode;
      state = m;
    };
  in {
    assertions = [
      {
        assertion = innerKm < departKm && departKm < outerKm;
        message = "cottage heating: rings must satisfy innerKm < departKm < outerKm (Joliette between home and the cottage)";
      }
    ];

    services.home-assistant.config = {
      # No `initial`, so the mode survives a restart.
      input_select.cottage_mode = {
        name = "Cottage mode";
        options = ["away" "preheat" "comfort"];
        icon = "mdi:home-thermometer";
      };

      "automation cottage" = [
        {
          alias = "Cottage - Pre-heat on approach";
          description = "Heat the cottage once someone inside the outer ring heads toward it";
          triggers = [
            {
              # A template, not numeric_state plus a condition: distance and
              # direction update separately, and this fires once both agree.
              trigger = "template";
              value_template = "{{ ${within outerKm} and is_state('${direction}', 'towards') }}";
            }
          ];
          conditions = [(isMode "away")];
          actions = [
            (select "preheat")
            (notify "Heading to the cottage: heating it to ${n comfort} °C.")
          ];
          mode = "single";
        }
        {
          alias = "Cottage - Comfort on arrival";
          description = "Past Joliette or at the cottage: keep it at comfort";
          triggers = [
            {
              trigger = "template";
              value_template = "{{ ${within innerKm} or ${occupied} }}";
            }
          ];
          conditions = [
            {
              condition = "template";
              value_template = "{{ not is_state('${mode}', 'comfort') }}";
            }
          ];
          actions = [(select "comfort")];
          mode = "single";
        }
        {
          alias = "Cottage - Cancel pre-heat";
          description = "A pre-heat that turns away, or stalls for ${n preheatTimeoutMin} minutes (a Joliette trip), goes back to away";
          triggers = [
            {
              trigger = "state";
              entity_id = direction;
              to = "away_from";
            }
            {
              trigger = "time_pattern";
              minutes = "/5";
            }
          ];
          conditions = [
            (isMode "preheat")
            {
              condition = "template";
              value_template = "{{ is_state('${direction}', 'away_from') or now() - states.${mode}.last_changed > timedelta(minutes=${n preheatTimeoutMin}) }}";
            }
          ];
          actions = [
            (select "away")
            (notify "Cottage pre-heat cancelled: back to ${n away} °C.")
          ];
          mode = "single";
        }
        {
          alias = "Cottage - Away on departure";
          description = "Nobody there and past Joliette for ${n departureDelayMin} minutes";
          triggers = [
            {
              trigger = "template";
              value_template = "{{ not ${occupied} and ${beyond departKm} }}";
              for.minutes = departureDelayMin;
            }
          ];
          conditions = [
            {
              condition = "template";
              value_template = "{{ not is_state('${mode}', 'away') }}";
            }
          ];
          actions = [(select "away")];
          mode = "single";
        }
        {
          alias = "Cottage - Safety net";
          description = "Comfort with nobody there for ${n safetyNetHours} hours goes back to away";
          triggers = [
            {
              trigger = "time_pattern";
              minutes = "/15";
            }
          ];
          conditions = [
            (isMode "comfort")
            {
              # Both clocks: zone.cottage can be empty for days before an
              # arrival, so its age alone would cancel a fresh comfort.
              condition = "template";
              value_template = "{{ not ${occupied} and now() - states.zone.cottage.last_changed > timedelta(hours=${n safetyNetHours}) and now() - states.${mode}.last_changed > timedelta(hours=${n safetyNetHours}) }}";
            }
          ];
          actions = [
            (select "away")
            (notify "Nobody at the cottage for ${n safetyNetHours} hours: back to ${n away} °C.")
          ];
          mode = "single";
        }
        {
          alias = "Cottage - Setpoints";
          description = "Push the mode's setpoint to every cottage thermostat, never during a Hilo challenge";
          triggers = [
            {
              trigger = "state";
              entity_id = mode;
              not_to = ["unknown" "unavailable"];
              id = "mode";
            }
            {
              trigger = "homeassistant";
              event = "start";
              id = "start";
            }
            {
              # Away only (see conditions): undoes a failed call or a dial
              # turned in the Hilo app. In comfort, a hand-set setpoint stays.
              trigger = "time_pattern";
              minutes = 0;
              id = "hourly";
            }
            {
              # Hilo restores its pre-challenge setpoints when one ends, and
              # mode changes during it were skipped: re-assert.
              trigger = "state";
              entity_id = defi;
              not_from = ["unknown" "unavailable"];
              to = "off";
              id = "challenge_end";
            }
          ];
          conditions = [
            {
              condition = "template";
              value_template = "{{ not (${challenge}) }}";
            }
            {
              condition = "template";
              value_template = "{{ trigger.id != 'hourly' or is_state('${mode}', 'away') }}";
            }
          ];
          variables.setpoint = "{{ ${n away} if is_state('${mode}', 'away') else ${n comfort} }}";
          actions = [
            {
              repeat = {
                for_each = thermostats;
                sequence = [
                  {
                    "if" = [
                      {
                        condition = "template";
                        value_template = "{{ states(repeat.item) not in ['unavailable', 'unknown'] and state_attr(repeat.item, 'temperature') | float(0) != setpoint | float }}";
                      }
                    ];
                    "then" = [
                      {
                        action = "climate.set_temperature";
                        target.entity_id = "{{ repeat.item }}";
                        data.temperature = "{{ setpoint }}";
                      }
                    ];
                  }
                ];
              };
            }
          ];
          mode = "queued";
        }
      ];
    };
  };
}
```

After substituting, the `let` must read like `outerKm = 72;` and `thermostats = ["climate.cottage_living_room" "climate.cottage_bedroom"];`, with no `_FROM_TASK_4` names left. `{lib, ...}` is unused if alejandra/deadnix complains; drop it then.

- [ ] **Step 2: Check the rendered config and the ring assertion**

Run:
```bash
git add -N modules/hosts/galactica/services/home-assistant-cottage.nix
grep -c _FROM_TASK_4 modules/hosts/galactica/services/home-assistant-cottage.nix
nice nix eval --json .#nixosConfigurations.galactica.config.services.home-assistant.config --apply 'c: { inherit (c) input_select; n = builtins.length c."automation cottage"; }'
```
Expected: `0` (grep exits 1), then JSON showing `cottage_mode` with three options, and `"n":6`.

Then prove the assertion fires, by evaluating with swapped rings:
```bash
nice nix eval .#nixosConfigurations.galactica.config.assertions --apply 'as: builtins.length (builtins.filter (a: !a.assertion) as)'
```
Expected: `0`. Temporarily set `innerKm` larger than `departKm`, rerun, expect `1`, then restore the value.

- [ ] **Step 3: Build galactica and run the heating check**

Run:
```bash
nice nix build --no-link .#nixosConfigurations.galactica.config.system.build.toplevel
nice nix build --no-link .#checks.x86_64-linux.heating-policy-test
```
Expected: both succeed.

- [ ] **Step 4: Commit, push and deploy**

```bash
just fmt
git add modules/hosts/galactica/services/home-assistant-cottage.nix
git commit -m "feat(galactica): cottage heating from phone proximity"
git push origin master
just deploy galactica
```
Then confirm Home Assistant accepted the config (a YAML error would disable the automations silently):
```bash
ssh galactica.bat-boa.ts.net "journalctl -u home-assistant --since '-10 min' | grep -iE 'invalid config|cottage' | head -20"
```
Expected: no `Invalid config` lines mentioning the cottage automations.

- [ ] **Step 5 (user): Live walkthrough**

Ask the user to run these in Developer Tools → States. Setting a state there is temporary: the next real update overwrites it, so do each scenario promptly. Before starting, set `input_select.cottage_mode` to `away` in the UI.

1. **Home → Joliette, cancelled.** Set `sensor.cottage_nearest_direction_of_travel` = `towards`, then `sensor.cottage_nearest_distance` = `outerKm − 1`. Expect mode `preheat` and a notification. Then set direction = `away_from`. Expect `away` and a "cancelled" notification.
2. **Home → cottage.** Distance `outerKm − 1` and direction `towards`: expect `preheat`. Then distance `innerKm − 1`: expect `comfort`.
3. **Errand to Joliette from the cottage.** In `comfort`, set `zone.cottage` = `0` and distance `departKm − 1`. Expect it to stay `comfort`.
4. **Departure.** Distance `departKm + 5`, `zone.cottage` = `0`. Expect `away` 30 minutes later. To shorten the wait, it's fine to just check the automation's trace shows its trigger armed.

- [ ] **Step 6: Verify the setpoints from the recorder**

After the walkthrough, run:
```bash
ssh galactica.bat-boa.ts.net "sudo nix shell nixpkgs#sqlite -c sqlite3 -readonly /var/lib/hass/home-assistant_v2.db \"
  SELECT datetime(s.last_updated_ts,'unixepoch','localtime'), m.entity_id, s.state,
         json_extract(a.shared_attrs, '$.temperature')
  FROM states s JOIN states_meta m USING(metadata_id) LEFT JOIN state_attributes a USING(attributes_id)
  WHERE (m.entity_id = 'input_select.cottage_mode' OR m.entity_id LIKE 'climate.%')
    AND s.last_updated_ts > strftime('%s','now','-2 hours')
  ORDER BY s.last_updated_ts;\""
```
Expected:
- each mode change is followed by the cottage thermostats moving to 20 (`preheat`/`comfort`) or 10 (`away`)
- none of home's climate entities (`climate.office`, `climate.living_room_1`, …) changes at those moments
- after the walkthrough the mode is `away` and the cottage sits at 10 °C

The challenge-end path can only be seen when a real Hilo challenge happens at the cottage. Its trigger matches home's tested `Heating - Baseboards` pattern (`to = "off"`). Note in the hand-off that it hasn't been verified live yet.

- [ ] **Step 7: Report**

Tell the user:
- the three ring values used
- the thermostats under control
- that the challenge-end re-apply hasn't been verified live and the next cottage challenge will show it
- that a real drive is the final test: the phone's location updates decide how early pre-heat starts
