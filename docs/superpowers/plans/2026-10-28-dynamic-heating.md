# Dynamic Heating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace galactica's fixed-hour heating automations with a per-zone weekly occupancy schedule, learned pre-heat, phone presence for the office, and three midnight-clearing boost buttons, as specified in `docs/superpowers/specs/2026-10-28-dynamic-heating-design.md`.

**Architecture:** Everything stays inside Home Assistant, generated from Nix. `zones.nix` holds the policy as data. `templates.nix` turns a zone into Jinja: one `plan` that computes the zone's target, reason and pre-heat state. `default.nix` wires that into template sensors, helpers and automations. A flake check renders the *generated* templates with a small Jinja harness that mimics the HA extensions they use, so every rule is unit-tested without a running HA.

**Tech Stack:** Nix (NixOS module, flake-parts check), Home Assistant 2026.5 YAML config (template sensors, automations, `input_boolean`, `input_number`), Jinja2 3.1 sandbox, Python `unittest`.

## Global Constraints

- Commit straight to `master`; no branches or worktrees. Conventional commits, scope `galactica` (docs: `docs(galactica)`). Never mention Claude.
- New files are invisible to `nix build` until `git add`ed; run `git add -N <path>` (or `git add`) before building.
- Run the tests with `nix build .#checks.x86_64-linux.heating-policy-test -L`.
- Format with `nix develop -c alejandra <files>` before committing (CI fails on unformatted Nix).
- **Nix sorts attribute names**, so YAML maps reach HA in alphabetical order. HA renders automation `variables` in that order, so a variable may only use variables that sort *before* it.
- `services.home-assistant.config` drops `null` values, so never rely on a Nix `null` reaching YAML (e.g. `to = null` on a trigger is silently removed).
- Use `builtins.toJSON` to put numbers into Jinja (`toString 0.4` is `"0.400000"`).
- Living area sensor: `sensor.living_area_temperature`. Heat pump: `climate.living_room_heat_pump`. Outdoor: `sensor.outdoor_weather_hilo`. Hilo challenge: `sensor.defi_hilo`. Presence: `person.alexandre_rosenfeld`.
- Baseboards (12): `climate.master_bedroom`, `climate.amanda_bedroom`, `climate.beas_bedroom`, `climate.bathroom`, `climate.office`, `climate.bathroom_downstairs`, `climate.living_room_2` (family room), `climate.living_room_1`, `climate.dining_room`, `climate.workshop_1`, `climate.workshop_2`, `climate.garage`. Hilo minimum 5°C = off.

## File Structure

| Path | Responsibility |
|---|---|
| `hosts/galactica/services/home-assistant-heating/zones.nix` (new) | Policy data only: each zone's windows, base, boost, presence, rate, devices |
| `hosts/galactica/services/home-assistant-heating/templates.nix` (new) | Pure Jinja generators: `plan`, `rate`, entity-name helpers, Hilo predicates |
| `hosts/galactica/services/home-assistant-heating/default.nix` (moved from `home-assistant-heating.nix`) | HA wiring: template sensors, helpers, automations, assertions |
| `hosts/galactica/services/home-assistant-heating/harness.py` (new) | Renders generated templates outside HA |
| `hosts/galactica/services/home-assistant-heating/test_heating.py` (new) | Unit tests over the generated config |
| `flake-modules/checks.nix` | New `heating-policy-test` check |
| `hosts/galactica/services/default.nix`, `home-assistant.nix` | Import path / comment update |

---

### Task 1: Move the module into a directory and add the template test harness

**Files:**
- Move: `hosts/galactica/services/home-assistant-heating.nix` → `hosts/galactica/services/home-assistant-heating/default.nix`
- Modify: `hosts/galactica/services/default.nix:23`, `hosts/galactica/services/home-assistant.nix:13`
- Create: `hosts/galactica/services/home-assistant-heating/harness.py`
- Create: `hosts/galactica/services/home-assistant-heating/test_heating.py`
- Modify: `flake-modules/checks.nix` (x86_64-only block)

**Interfaces:**
- Produces (harness.py): `MONDAY = 0`, `SATURDAY = 5`, `at(day, "HH:MM") -> datetime`, `Hass(now, states)`, where `states` maps entity_id to a state or a `(state, attrs)` tuple. `Hass.set(entity_id, state, attrs=None)`, `Hass.render(template, this=None, **variables) -> value`, `render_entity(hass, kind, unique_id, this=None) -> SimpleNamespace(state, value, attributes)`, `automation(alias) -> dict`, `render_variables(hass, alias, trigger) -> dict`.
- Produces (check): `checks.x86_64-linux.heating-policy-test`, with env `HEATING_CONFIG` holding JSON `{template, input_boolean, input_number, automation}` from galactica's `services.home-assistant.config`.

- [ ] **Step 1: Move the file and fix references**

```bash
cd /home/arosenfeld/Code/nixos
mkdir -p hosts/galactica/services/home-assistant-heating
git mv hosts/galactica/services/home-assistant-heating.nix hosts/galactica/services/home-assistant-heating/default.nix
sed -i 's|./home-assistant-heating.nix|./home-assistant-heating|' hosts/galactica/services/default.nix
sed -i 's|# - Heating automations live in ./home-assistant-heating.nix|# - Heating automations live in ./home-assistant-heating/|' hosts/galactica/services/home-assistant.nix
grep -n "home-assistant-heating" hosts/galactica/services/default.nix hosts/galactica/services/home-assistant.nix
```

Expected: two lines, `./home-assistant-heating` and `./home-assistant-heating/`.

- [ ] **Step 2: Write the harness**

Create `hosts/galactica/services/home-assistant-heating/harness.py`:

```python
"""Render the heating policy's generated Home Assistant templates.

HEATING_CONFIG points at JSON the flake check writes from galactica's
services.home-assistant.config. Only the HA template extensions these
templates use are implemented, under StrictUndefined: a template that
reaches for anything else fails loudly instead of rendering wrong.
"""

import ast
import json
import math
import os
import statistics
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from jinja2 import StrictUndefined
from jinja2.sandbox import ImmutableSandboxedEnvironment

with open(os.environ["HEATING_CONFIG"]) as f:
    CONFIG = json.load(f)

MONDAY, SATURDAY = 0, 5
TORONTO = timezone(timedelta(hours=-4))  # EDT; no test crosses a DST change
_NO_DEFAULT = object()


def at(day, hhmm):
    """Local time on Monday 2026-10-26 plus `day` days."""
    hour, minute = map(int, hhmm.split(":"))
    return datetime(2026, 10, 26 + day, hour, minute, tzinfo=TORONTO)


def parse(text):
    """Turn rendered text into a value, as HA's parse_result does."""
    text = text.strip()
    try:
        value = ast.literal_eval(text)
    except (ValueError, SyntaxError):
        return text
    return value if isinstance(value, (bool, int, float, list, dict, type(None))) else text


def _float(value, default=_NO_DEFAULT):
    # HA's float filter raises without a default, unlike Jinja's.
    try:
        return float(value)
    except (TypeError, ValueError):
        if default is _NO_DEFAULT:
            raise ValueError(f"float({value!r}) with no default")
        return default


def _is_number(value):
    try:
        return math.isfinite(float(value))
    except (TypeError, ValueError):
        return False


class Hass:
    def __init__(self, now, states=None):
        self.now = now
        self.entities = {}
        for entity_id, value in (states or {}).items():
            state, attrs = value if isinstance(value, tuple) else (value, {})
            self.set(entity_id, state, attrs)

    def set(self, entity_id, state, attrs=None):
        self.entities[entity_id] = (str(state), dict(attrs or {}))

    def states(self, entity_id):
        return self.entities.get(entity_id, ("unknown", {}))[0]

    def state_attr(self, entity_id, name):
        return self.entities.get(entity_id, ("unknown", {}))[1].get(name)

    def is_state(self, entity_id, value):
        return self.states(entity_id) in (value if isinstance(value, list) else [value])

    def render(self, template, this=None, **variables):
        env = ImmutableSandboxedEnvironment(undefined=StrictUndefined)
        env.globals.update(
            now=lambda: self.now,
            states=self.states,
            state_attr=self.state_attr,
            is_state=self.is_state,
        )
        env.filters.update(states=self.states, float=_float, median=statistics.median, is_number=_is_number)
        env.tests["is_number"] = _is_number
        this = this or SimpleNamespace(state="unknown", attributes={})
        return parse(env.from_string(template).render(this=this, **variables))


def template_entity(kind, unique_id):
    for block in CONFIG["template"]:
        for entity in block.get(kind, []):
            if entity.get("unique_id") == unique_id:
                return entity
    raise KeyError(f"no template {kind} with unique_id {unique_id}")


def render_entity(hass, kind, unique_id, this=None):
    """Render a template entity. Pass the previous result as `this` to latch."""
    entity = template_entity(kind, unique_id)
    value = hass.render(entity["state"], this)
    attributes = {name: hass.render(t, this) for name, t in entity.get("attributes", {}).items()}
    return SimpleNamespace(state=str(value), value=value, attributes=attributes)


def automation(alias):
    for entry in CONFIG["automation"]:
        if entry["alias"] == alias:
            return entry
    raise KeyError(f"no automation {alias!r}")


def render_variables(hass, alias, trigger):
    """Render an automation's variables in order, each seeing the earlier ones."""
    values = {}
    for name, template in automation(alias).get("variables", {}).items():
        values[name] = hass.render(template, trigger=trigger, **values)
    return values
```

- [ ] **Step 3: Write a characterization test of the existing living-area sensor**

Create `hosts/galactica/services/home-assistant-heating/test_heating.py`:

```python
import unittest
from types import SimpleNamespace

from harness import MONDAY, SATURDAY, Hass, at, automation, render_entity, render_variables

LIVING = "sensor.heating_living_area_target"
OFFICE = "sensor.heating_office_target"


class LivingAreaTemperature(unittest.TestCase):
    def render(self, ir, lr, dr):
        hass = Hass(at(MONDAY, "12:00"), {
            "sensor.living_room_ir_temperature_2": ir,
            "sensor.living_room_1_temperature": lr,
            "sensor.dining_room_temperature": dr,
        })
        return render_entity(hass, "sensor", "living_area_temperature").value

    def test_median_of_the_three(self):
        self.assertEqual(self.render("21.5", "20.0", "19.5"), 20.0)

    def test_ignores_an_unavailable_sensor(self):
        self.assertEqual(self.render("unavailable", "20.0", "19.0"), 19.5)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 4: Wire the check**

In `flake-modules/checks.nix`, inside the `inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {` block, after `cylon-link-config = …;`, add:

```nix
        # The heating policy's generated Home Assistant templates, rendered
        # outside HA by a harness that mimics the extensions they use.
        heating-policy-test = let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          hass = self.nixosConfigurations.galactica.config.services.home-assistant.config;
          config = pkgs.writeText "heating.json" (builtins.toJSON {
            template = hass.template;
            input_boolean = hass.input_boolean or {};
            input_number = hass.input_number or {};
            automation = hass."automation heating";
          });
        in
          pkgs.runCommand "heating-policy-test" {
            nativeBuildInputs = [(pkgs.python3.withPackages (ps: [ps.jinja2]))];
            HEATING_CONFIG = config;
          } ''
            cp ${../hosts/galactica/services/home-assistant-heating}/*.py .
            python3 -m unittest discover -v -s . -p 'test_*.py'
            touch $out
          '';
```

- [ ] **Step 5: Run the tests**

```bash
git add hosts/galactica/services/home-assistant-heating flake-modules/checks.nix
nix build .#checks.x86_64-linux.heating-policy-test -L
```

Expected: `Ran 2 tests … OK`. If the median test fails, the harness is wrong, not the sensor: that template is deployed and working.

- [ ] **Step 6: Confirm galactica still builds, format, commit**

```bash
nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link
nix develop -c alejandra flake-modules/checks.nix hosts/galactica/services
git add -A hosts/galactica/services flake-modules/checks.nix
git commit -m "test(galactica): render the heating templates in a flake check"
```

---

### Task 2: Zones, the `plan` template, target sensors, helpers and presence

**Files:**
- Create: `hosts/galactica/services/home-assistant-heating/zones.nix`
- Create: `hosts/galactica/services/home-assistant-heating/templates.nix`
- Modify: `hosts/galactica/services/home-assistant-heating/default.nix`
- Test: `hosts/galactica/services/home-assistant-heating/test_heating.py`

**Interfaces:**
- Produces (templates.nix, `import ./templates.nix {inherit lib;}`): `minutes "HH:MM" -> int`, `windows [[from to target]] -> [[int int number]]`, `hiloActive`, `hiloReduction` (Jinja boolean expressions), `awayEntity = "binary_sensor.alexandre_away"`, `targetEntity zone -> "sensor.heating_<zone>_target"`, `boostEntity helper -> "input_boolean.heating_boost_<helper>"`, `rateEntity helper -> "input_number.heating_rate_<helper>"`, `rate zone -> Jinja number expression`, `plan zone -> Jinja that sets namespace p`.
- Produces (HA entities): `sensor.heating_<zone>_target` for each zone (unique_id `heating_<zone>_target`) with attributes `reason window minutes start since from_temp assisted reached`. Also `input_boolean.heating_boost_{living_area,bedrooms,office}`, `input_number.heating_rate_{living_area,office,family_room}`, and `binary_sensor.alexandre_away` (unique_id `alexandre_away`).
- Produces (default.nix let): `tpl`, `zones` (defaults merged), `pretty`, `learning`, `boostHelpers`, `living`, `targetAttributes`.
- Reasons: `base`, `schedule`, `preheat`, `boost`, `away`.

- [ ] **Step 1: Write the failing tests**

Append to `test_heating.py`, before `if __name__ == "__main__":`:

```python
def target(zone, now, states=None, this=None):
    return render_entity(Hass(now, states), "sensor", f"heating_{zone}_target", this)


def office(now, temp="18.0", rate="0", extra=None, this=None):
    return target("office", now, {
        "sensor.office_temperature": temp,
        "input_number.heating_rate_office": rate,
        **(extra or {}),
    }, this)


class OfficeTarget(unittest.TestCase):
    def test_base_before_preheat_shows_start(self):
        r = office(at(MONDAY, "06:00"))
        # (21 - 18) / 1.5 °C/h seed = 2 h before 08:30
        self.assertEqual((r.value, r.attributes["reason"], r.attributes["start"]), (16, "base", "06:30"))

    def test_preheats_from_the_seed_rate(self):
        r = office(at(MONDAY, "06:45"))
        self.assertEqual(
            (r.value, r.attributes["reason"], r.attributes["minutes"], r.attributes["from_temp"]),
            (21, "preheat", 105, 18.0),
        )

    def test_learned_rate_shortens_the_lead(self):
        r = office(at(MONDAY, "06:45"), rate="3")
        self.assertEqual((r.value, r.attributes["start"]), (16, "07:30"))

    def test_preheat_latches_once_the_room_is_warm(self):
        first = office(at(MONDAY, "06:45"))
        r = office(at(MONDAY, "07:30"), temp="21.0", this=first)
        self.assertEqual(
            (r.value, r.attributes["reason"], r.attributes["from_temp"], r.attributes["reached"]),
            (21, "preheat", 18.0, True),
        )

    def test_a_warm_room_without_latch_waits(self):
        self.assertEqual(office(at(MONDAY, "07:30"), temp="21.0").attributes["reason"], "base")

    def test_weekday_windows(self):
        for hhmm, want in {"09:00": 21, "12:30": 21, "18:00": 19, "21:00": 21, "23:59": 21, "02:00": 16}.items():
            with self.subTest(hhmm):
                self.assertEqual(office(at(MONDAY, hhmm), temp="21.0").value, want)

    def test_evening_preheat_back_to_21(self):
        # (21 - 19) / 1.5 °C/h = 80 min before 20:30
        self.assertEqual(office(at(MONDAY, "18:00"), temp="19.0").attributes["start"], "19:10")

    def test_weekend(self):
        self.assertEqual(office(at(SATURDAY, "10:00"), temp="19.0").value, 19)
        self.assertEqual(office(at(SATURDAY, "07:00"), temp="16.0").attributes["reason"], "preheat")

    def test_away_drops_to_base(self):
        r = office(at(MONDAY, "10:00"), extra={"binary_sensor.alexandre_away": "on"})
        self.assertEqual((r.value, r.attributes["reason"]), (16, "away"))

    def test_boost_beats_away(self):
        r = office(at(MONDAY, "10:00"), extra={
            "binary_sensor.alexandre_away": "on",
            "input_boolean.heating_boost_office": "on",
        })
        self.assertEqual((r.value, r.attributes["reason"]), (21, "boost"))


def living(now, temp="19.0", rate="0", extra=None, this=None):
    return target("living_area", now, {
        "sensor.living_area_temperature": temp,
        "input_number.heating_rate_living_area": rate,
        **(extra or {}),
    }, this)


class LivingAreaTarget(unittest.TestCase):
    def test_morning_preheat_from_the_seed_rate(self):
        # (20 - 19) / 0.4 °C/h = 150 min before 07:00
        r = living(at(MONDAY, "04:00"))
        self.assertEqual((r.value, r.attributes["start"]), (18, "04:30"))
        self.assertEqual(living(at(MONDAY, "04:40")).attributes["reason"], "preheat")

    def test_learned_rate(self):
        self.assertEqual(living(at(MONDAY, "04:00"), rate="1").attributes["start"], "06:00")

    def test_weekday_windows(self):
        for hhmm, want in {"07:30": 20, "12:00": 19, "17:30": 20, "21:00": 18}.items():
            with self.subTest(hhmm):
                self.assertEqual(living(at(MONDAY, hhmm), temp="20.0").value, want)

    def test_afternoon_preheat_start(self):
        r = living(at(MONDAY, "12:00"))
        self.assertEqual((r.value, r.attributes["reason"], r.attributes["start"]), (19, "schedule", "14:30"))

    def test_weekend_all_day(self):
        self.assertEqual(living(at(SATURDAY, "12:00"), temp="20.0").value, 20)

    def test_boost(self):
        r = living(at(MONDAY, "21:00"), extra={"input_boolean.heating_boost_living_area": "on"})
        self.assertEqual((r.value, r.attributes["reason"]), (21, "boost"))


class OtherZones(unittest.TestCase):
    def test_bedrooms_and_bathroom(self):
        self.assertEqual(target("bedrooms", at(MONDAY, "12:00")).value, 18)
        self.assertEqual(target("bathroom", at(MONDAY, "12:00")).value, 19)
        boost = {"input_boolean.heating_boost_bedrooms": "on"}
        self.assertEqual(target("bedrooms", at(MONDAY, "12:00"), boost).value, 20)
        self.assertEqual(target("bathroom", at(MONDAY, "12:00"), boost).value, 20)

    def test_downstairs_bathroom_follows_the_office(self):
        states = {"sensor.bathroom_downstairs_temperature": "19.0", "input_number.heating_rate_office": "0"}
        self.assertEqual(target("bathroom_downstairs", at(MONDAY, "09:00"), states).value, 19)
        away = {**states, "binary_sensor.alexandre_away": "on"}
        self.assertEqual(target("bathroom_downstairs", at(MONDAY, "09:00"), away).value, 16)
        boost = {**away, "input_boolean.heating_boost_office": "on"}
        self.assertEqual(target("bathroom_downstairs", at(MONDAY, "09:00"), boost).value, 19)

    def test_family_room(self):
        states = {"sensor.living_room_2_temperature": "18.0", "input_number.heating_rate_family_room": "0"}
        # (20 - 18) / 1.0 °C/h seed = 2 h before 17:00
        r = target("family_room", at(MONDAY, "16:30"), states)
        self.assertEqual((r.value, r.attributes["reason"]), (20, "preheat"))
        self.assertEqual(target("family_room", at(MONDAY, "12:00"), {**states, "sensor.living_room_2_temperature": "20.0"}).value, 16)
        self.assertEqual(target("family_room", at(SATURDAY, "09:00"), states).value, 20)

    def test_unheated(self):
        self.assertEqual(target("unheated", at(MONDAY, "12:00")).value, 5)


class Away(unittest.TestCase):
    def test_states(self):
        for person, want in {"not_home": True, "work": True, "home": False, "unknown": False, "unavailable": False}.items():
            with self.subTest(person):
                hass = Hass(at(MONDAY, "10:00"), {"person.alexandre_rosenfeld": person})
                self.assertEqual(render_entity(hass, "binary_sensor", "alexandre_away").value, want)
```

- [ ] **Step 2: Run to verify they fail**

```bash
nix build .#checks.x86_64-linux.heating-policy-test -L
```

Expected: FAIL, `KeyError: 'no template sensor with unique_id heating_office_target'` (and similar).

- [ ] **Step 3: Write zones.nix**

Create `hosts/galactica/services/home-assistant-heating/zones.nix`:

```nix
# The heating policy: what each zone should be, and when. Edit here to change
# a schedule; default.nix and templates.nix turn this into Home Assistant.
#
#   base         °C outside every window (5 is a Hilo baseboard's off)
#   weekday,     [from to °C] windows, "HH:MM", "24:00" for midnight; they
#   weekend      may not wrap midnight. Each is reached *by* `from`: zones
#                with a `rate` pre-heat toward the next warmer window.
#   boost        a one-click input_boolean (cleared at midnight) and its °C
#   presence     drop to base once the user has been away 30 minutes
#   rate         warm-up rate in °C/h: the input_number `helper` (learned by
#                the zone of that name), a `seed` until one is learned, and
#                `maxLead`, the most minutes a pre-heat may start early
#   temperature  the room sensor pre-heat and learning read
#   devices      the baseboards this zone's target drives
#   assist       an entity whose "on" marks a pre-heat as helped, so its
#                rate is not learned
{
  # Heat pump zone. Its own baseboards (living_room_1, dining_room) only
  # close a shortfall or back it up; see default.nix.
  living_area = {
    temperature = "sensor.living_area_temperature";
    base = 18;
    weekday = [["07:00" "08:00" 20] ["08:00" "17:00" 19] ["17:00" "20:30" 20]];
    weekend = [["07:00" "20:30" 20]];
    boost = {
      helper = "living_area";
      target = 21;
    };
    rate = {
      helper = "living_area";
      seed = 0.4;
      maxLead = 180;
    };
    assist = "binary_sensor.living_area_shortfall";
  };

  # The heat pump carries the bedrooms; their baseboards are a floor.
  bedrooms = {
    base = 18;
    boost = {
      helper = "bedrooms";
      target = 20;
    };
    devices = ["climate.master_bedroom" "climate.amanda_bedroom" "climate.beas_bedroom"];
  };
  bathroom = {
    base = 19;
    boost = {
      helper = "bedrooms";
      target = 20;
    };
    devices = ["climate.bathroom"];
  };

  # Basement: where the user works, gated on their phone.
  office = {
    temperature = "sensor.office_temperature";
    base = 16;
    weekday = [["08:30" "17:00" 21] ["17:00" "20:30" 19] ["20:30" "24:00" 21]];
    weekend = [["08:30" "20:30" 19] ["20:30" "24:00" 21]];
    presence = true;
    boost = {
      helper = "office";
      target = 21;
    };
    rate = {
      helper = "office";
      seed = 1.5;
      maxLead = 120;
    };
    devices = ["climate.office"];
  };
  bathroom_downstairs = {
    temperature = "sensor.bathroom_downstairs_temperature";
    base = 16;
    weekday = [["08:30" "24:00" 19]];
    weekend = [["08:30" "24:00" 19]];
    presence = true;
    boost = {
      helper = "office";
      target = 19;
    };
    rate = {
      helper = "office";
      seed = 1.5;
      maxLead = 120;
    };
    devices = ["climate.bathroom_downstairs"];
  };

  # Family room (still living_room_2 in HA): too far for the heat pump.
  family_room = {
    temperature = "sensor.living_room_2_temperature";
    base = 16;
    weekday = [["17:00" "20:30" 20]];
    weekend = [["08:00" "20:30" 20]];
    rate = {
      helper = "family_room";
      seed = 1.0;
      maxLead = 120;
    };
    devices = ["climate.living_room_2"];
  };

  # Baseboards not ready yet.
  unheated = {
    base = 5;
    devices = ["climate.workshop_1" "climate.workshop_2" "climate.garage"];
  };
}
```

- [ ] **Step 4: Write templates.nix**

Create `hosts/galactica/services/home-assistant-heating/templates.nix`:

```nix
# Jinja generators for the heating policy, as pure functions of a zone from
# zones.nix (with default.nix's defaults merged in). test_heating.py renders
# their output.
{lib}: let
  num = builtins.toJSON;
in rec {
  minutes = hhmm: let
    parts = lib.splitString ":" hhmm;
  in
    lib.toIntBase10 (builtins.elemAt parts 0) * 60 + lib.toIntBase10 (builtins.elemAt parts 1);
  windows = map (w: [(minutes (builtins.elemAt w 0)) (minutes (builtins.elemAt w 1)) (builtins.elemAt w 2)]);

  hiloActive = "states('sensor.defi_hilo') in ['pre_heat', 'reduction', 'on', 'recovery']";
  hiloReduction = "states('sensor.defi_hilo') in ['reduction', 'on']";

  awayEntity = "binary_sensor.alexandre_away";
  targetEntity = zone: "sensor.heating_${zone}_target";
  boostEntity = helper: "input_boolean.heating_boost_${helper}";
  rateEntity = helper: "input_number.heating_rate_${helper}";

  # The learned warm-up rate in °C/h, or the seed until one is learned: an
  # input_number starts at its minimum, 0.
  rate = zone: let
    learned = "states('${rateEntity zone.rate.helper}') | float(0)";
  in "(([${learned}, 3] | min) if ${learned} >= 0.2 else ${num zone.rate.seed})";

  # Pre-heat toward the next window today that is warmer than now, starting
  # (target - temp) / rate early, capped at maxLead. Once started it latches
  # through `this` until the window opens, so the lead shrinking as the room
  # warms cannot switch it back off. `since`, `from_temp`, `assisted` and
  # `reached` feed rate learning.
  preheat = zone: let
    maxLead = num zone.rate.maxLead;
    assist = lib.optionalString (zone.assist != null) " or is_state('${zone.assist}', 'on')";
  in ''
    {%- set temp = states('${zone.temperature}') | float(none) %}
    {%- set rate = ${rate zone} %}
    {%- set next = namespace(w=none) %}
    {%- for w in wins if w[0] > m and w[2] > p.target and next.w is none %}
      {%- set next.w = w %}
    {%- endfor %}
    {%- if next.w is not none %}
      {%- set nw = next.w %}
      {%- set lead = ${maxLead} if temp is none else [0, [(nw[2] - temp) / rate * 60, ${maxLead}] | min] | max %}
      {%- set p.start = '%02d:%02d' | format(((nw[0] - lead) // 60) | int, ((nw[0] - lead) % 60) | int) %}
      {%- set latched = prev.get('reason') == 'preheat' and prev.get('window') == nw[0] %}
      {%- if latched or m >= nw[0] - lead %}
        {%- set p.target = nw[2] %}
        {%- set p.reason = 'preheat' %}
        {%- set p.window = nw[0] %}
        {%- set p.minutes = nw[0] - m %}
        {%- set p.since = prev.get('since') if latched else n.timestamp() %}
        {%- set p.from_temp = prev.get('from_temp') if latched else temp %}
        {%- set p.assisted = (latched and prev.get('assisted', false))${assist} %}
        {%- set p.reached = (latched and prev.get('reached', false)) or (temp is not none and temp >= nw[2]) %}
      {%- endif %}
    {%- endif %}
  '';

  # Sets namespace `p` to what the zone wants now. Highest precedence first:
  # boost, away, then the schedule (with pre-heat), else base.
  plan = zone: let
    boostOn =
      if zone.boost == null
      then "false"
      else "is_state('${boostEntity zone.boost.helper}', 'on')";
    awayOn =
      if zone.presence
      then "is_state('${awayEntity}', 'on')"
      else "false";
  in ''
    {%- set n = now() %}
    {%- set m = n.hour * 60 + n.minute %}
    {%- set prev = this.attributes %}
    {%- set p = namespace(target=${num zone.base}, reason='base', window=none, minutes=none, start=none, since=none, from_temp=none, assisted=false, reached=false) %}
    {%- if ${boostOn} %}
      {%- set p.target = ${
      if zone.boost == null
      then "none"
      else num zone.boost.target
    } %}
      {%- set p.reason = 'boost' %}
    {%- elif ${awayOn} %}
      {%- set p.reason = 'away' %}
    {%- else %}
      {%- set wins = ${builtins.toJSON (windows zone.weekday)} if n.weekday() < 5 else ${builtins.toJSON (windows zone.weekend)} %}
      {%- for w in wins if w[0] <= m < w[1] %}
        {%- set p.target = w[2] %}
        {%- set p.reason = 'schedule' %}
      {%- endfor %}
    ${lib.optionalString (zone.rate != null) (preheat zone)}
    {%- endif %}
  '';
}
```

- [ ] **Step 5: Wire zones, sensors, helpers and presence into default.nix**

In `default.nix`, add to the top of the `let` block (right after `{lib, ...}: let`):

```nix
  tpl = import ./templates.nix {inherit lib;};
  pretty = lib.replaceStrings ["_"] [" "];

  zoneDefaults = {
    temperature = null;
    weekday = [];
    weekend = [];
    boost = null;
    presence = false;
    rate = null;
    devices = [];
    assist = null;
  };
  zones = lib.mapAttrs (_: z: zoneDefaults // z) (import ./zones.nix);

  # A zone learns the rate helper named after it; others only borrow one.
  learning = lib.filterAttrs (name: z: z.rate != null && z.rate.helper == name) zones;
  boostHelpers = lib.unique (lib.concatMap (z: lib.optional (z.boost != null) z.boost.helper) (lib.attrValues zones));

  living = tpl.targetEntity "living_area";
  targetAttributes = ["reason" "window" "minutes" "start" "since" "from_temp" "assisted" "reached"];
```

Change the module body's opening from `in {` / `services.home-assistant.config = {` to add the assertions and helpers:

```nix
in {
  # Pre-heat never looks past midnight, so no window may need to start
  # before it.
  assertions = lib.concatLists (lib.mapAttrsToList (name: z:
    lib.optionals (z.rate != null) (map (w: {
      assertion = tpl.minutes (builtins.elemAt w 0) >= z.rate.maxLead;
      message = "heating zone ${name}: the ${builtins.elemAt w 0} window would pre-heat before midnight";
    }) (z.weekday ++ z.weekend)))
  zones);

  services.home-assistant.config = {
    input_boolean = lib.listToAttrs (map (h:
      lib.nameValuePair "heating_boost_${h}" {
        name = "Boost ${pretty h}";
        icon = "mdi:fire";
      })
    boostHelpers);

    input_number = lib.mapAttrs' (name: _:
      lib.nameValuePair "heating_rate_${name}" {
        name = "Heating rate ${pretty name}";
        min = 0;
        max = 3;
        step = 0.01;
        mode = "box";
        unit_of_measurement = "°C/h";
      })
    learning;
```

In the `template` list's `sensor = [ … ];`, after the existing living-area temperature entry, append the target sensors (make the list `[ {living area temperature} ] ++ lib.mapAttrsToList …`):

```nix
        sensor =
          [
            # (existing "Living area temperature" entry, unchanged)
          ]
          ++ lib.mapAttrsToList (name: z: {
            name = "Heating ${pretty name} target";
            unique_id = "heating_${name}_target";
            unit_of_measurement = "°C";
            device_class = "temperature";
            state = "${tpl.plan z}{{ p.target }}";
            attributes = lib.genAttrs targetAttributes (a: "${tpl.plan z}{{ p.${a} }}");
          })
          zones;
```

In `binary_sensor = [ … ];`, append:

```nix
          {
            # Not home for 30 minutes; unknown counts as home, so heat fails warm.
            name = "Alexandre away";
            unique_id = "alexandre_away";
            delay_on.minutes = 30;
            state = "{{ states('person.alexandre_rosenfeld') not in ['home', 'unknown', 'unavailable'] }}";
          }
```

The old `hiloActive`/`hiloReduction` let bindings remain for now (the old automations still use them). Task 5 removes them.

- [ ] **Step 6: Run the tests**

```bash
git add -N hosts/galactica/services/home-assistant-heating
nix build .#checks.x86_64-linux.heating-policy-test -L
```

Expected: all tests pass. If a `start` string comes out as e.g. `6:30`, the `format` filter received floats. Check that the `| int` is applied to both arguments.

- [ ] **Step 7: Build galactica, format, commit**

```bash
nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link
nix develop -c alejandra hosts/galactica/services/home-assistant-heating
git add hosts/galactica/services/home-assistant-heating
git commit -m "feat(galactica): per-zone heating targets with learned pre-heat"
```

---

### Task 3: Living-area shortfall, rebased backup, and the living baseboards target

**Files:**
- Modify: `hosts/galactica/services/home-assistant-heating/default.nix`
- Test: `hosts/galactica/services/home-assistant-heating/test_heating.py`

**Interfaces:**
- Consumes: `living`, `tpl.rate`, `zones.living_area` (Task 2).
- Produces: `binary_sensor.living_area_shortfall` (unique_id `living_area_shortfall`), the rebased `binary_sensor.living_area_needs_backup`, and `sensor.heating_living_baseboards_target` (unique_id `heating_living_baseboards_target`). Let bindings `backupFloor` (redefined) and `livingBaseboards`.

- [ ] **Step 1: Write the failing tests**

Append to `test_heating.py`:

```python
def living_binary(unique_id, temp, target, reason, minutes=None, this="off", extra=None):
    hass = Hass(at(MONDAY, "06:30"), {
        "sensor.living_area_temperature": temp,
        LIVING: (target, {"reason": reason, "minutes": minutes}),
        "input_number.heating_rate_living_area": "0",
        **(extra or {}),
    })
    return render_entity(hass, "binary_sensor", unique_id, SimpleNamespace(state=this, attributes={})).value


class Shortfall(unittest.TestCase):
    def test_cases(self):
        cases = [
            # temp, target, reason, minutes, this, want
            ("19.5", "20", "preheat", 30, "off", True),   # 19.5 + 0.4 * 0.5 = 19.7 < 20
            ("19.5", "20", "preheat", 60, "off", False),  # more than 45 min to go
            ("19.9", "20", "preheat", 30, "off", False),  # projected 20.1
            ("19.8", "20", "schedule", None, "on", True),  # keeps going into the window
            ("18.8", "19", "schedule", None, "on", False),  # not a comfort window
            ("20.5", "21", "boost", None, "off", True),
            ("20.0", "20", "preheat", 10, "on", False),  # reached
        ]
        for temp, tgt, reason, minutes, this, want in cases:
            with self.subTest((temp, tgt, reason, minutes, this)):
                self.assertEqual(living_binary("living_area_shortfall", temp, tgt, reason, minutes, this), want)


class Backup(unittest.TestCase):
    def test_cases(self):
        cases = [
            ("16.5", "base", "off", True),      # night floor 17
            ("17.5", "schedule", "off", True),  # day floor 18
            ("18.2", "schedule", "off", False),
            ("18.5", "schedule", "on", True),   # holds until floor + 1
        ]
        for temp, reason, this, want in cases:
            with self.subTest((temp, reason, this)):
                self.assertEqual(living_binary("living_area_needs_backup", temp, "19", reason, None, this), want)


class LivingBaseboardsTarget(unittest.TestCase):
    def render(self, shortfall, backup, reason):
        hass = Hass(at(MONDAY, "06:30"), {
            LIVING: ("20", {"reason": reason}),
            "binary_sensor.living_area_shortfall": shortfall,
            "binary_sensor.living_area_needs_backup": backup,
        })
        return render_entity(hass, "sensor", "heating_living_baseboards_target").value

    def test_cases(self):
        self.assertEqual(self.render("on", "off", "preheat"), 20)
        self.assertEqual(self.render("off", "on", "base"), 18)
        self.assertEqual(self.render("off", "on", "schedule"), 19)
        self.assertEqual(self.render("off", "off", "schedule"), 5)
```

- [ ] **Step 2: Run to verify they fail**

```bash
nix build .#checks.x86_64-linux.heating-policy-test -L
```

Expected: FAIL. `Shortfall` and `LivingBaseboardsTarget` raise `KeyError` for the missing unique_ids, and `Backup` fails its `base`/`schedule` floors (the old template keys on the clock).

- [ ] **Step 3: Implement**

In the `let` block of `default.nix`, replace the old `backupFloor` definition with:

```nix
  # Last-resort floor for the living/dining baseboards: 17 at night, 18 by day.
  backupFloor = "(17 if state_attr('${living}', 'reason') == 'base' else 18)";
  livingBaseboards = tpl.targetEntity "living_baseboards";
```

The old `backupTarget` still refers to `backupFloor`; it keeps evaluating until Task 5 removes it.

Append to the `sensor` list (after the `mapAttrsToList` part, as `++ [ … ]`):

```nix
          ++ [
            {
              # The living/dining baseboards: off, unless the heat pump is
              # about to miss a comfort window (shortfall) or cannot hold the
              # floor at all (backup).
              name = "Heating living baseboards target";
              unique_id = "heating_living_baseboards_target";
              unit_of_measurement = "°C";
              device_class = "temperature";
              state = ''
                {%- if is_state('binary_sensor.living_area_shortfall', 'on') %}{{ states('${living}') }}
                {%- elif is_state('binary_sensor.living_area_needs_backup', 'on') %}{{ ${backupFloor} + 1 }}
                {%- else %}5
                {%- endif %}
              '';
            }
          ];
```

In `binary_sensor`, the existing `Living area needs backup` entry keeps its template text, which already reads `${backupFloor}`. Append the shortfall sensor:

```nix
          {
            # The heat pump will miss the comfort window: within 45 minutes
            # of it, temp + rate × time left is short of the target. Holds
            # until the room gets there or the window ends; a boost always
            # wants help.
            name = "Living area shortfall";
            unique_id = "living_area_shortfall";
            state = ''
              {%- set target = states('${living}') | float(none) %}
              {%- set temp = states('sensor.living_area_temperature') | float(none) %}
              {%- set reason = state_attr('${living}', 'reason') %}
              {%- set minutes = state_attr('${living}', 'minutes') %}
              {%- if target is none or temp is none or temp >= target %}{{ false }}
              {%- elif reason == 'boost' %}{{ true }}
              {%- elif this.state == 'on' and (reason == 'preheat' or (reason == 'schedule' and target >= 20)) %}{{ true }}
              {%- elif reason == 'preheat' %}{{ minutes is not none and minutes <= 45 and temp + ${tpl.rate zones.living_area} * minutes / 60 < target }}
              {%- else %}{{ false }}
              {%- endif %}
            '';
          }
```

- [ ] **Step 4: Run the tests**

```bash
nix build .#checks.x86_64-linux.heating-policy-test -L
```

Expected: all pass.

- [ ] **Step 5: Build, format, commit**

```bash
nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link
nix develop -c alejandra hosts/galactica/services/home-assistant-heating
git add hosts/galactica/services/home-assistant-heating
git commit -m "feat(galactica): bring in the living/dining baseboards when the heat pump will miss a window"
```

---

### Task 4: Drive the heat pump from the living-area target

**Files:**
- Modify: `hosts/galactica/services/home-assistant-heating/default.nix` (the `Heating - Heat pump` automation)
- Test: `hosts/galactica/services/home-assistant-heating/test_heating.py`

**Interfaces:**
- Consumes: `living`, `tpl.hiloReduction`, `tpl.boostEntity` (Task 2).
- Produces: automation `Heating - Heat pump` with variables `current`, `resend`, `setpoint`, `want` (alphabetical; each uses only earlier ones).

- [ ] **Step 1: Write the failing tests**

Append to `test_heating.py`:

```python
def heat_pump(temp, target, current="off", outdoor="8", boost="off", defi="off", trigger_id="1"):
    hass = Hass(at(MONDAY, "06:30"), {
        "sensor.living_area_temperature": temp,
        LIVING: target,
        "climate.living_room_heat_pump": current,
        "sensor.outdoor_weather_hilo": outdoor,
        "input_boolean.heating_boost_living_area": boost,
        "sensor.defi_hilo": defi,
    })
    return render_variables(hass, "Heating - Heat pump", {"id": trigger_id})


class HeatPump(unittest.TestCase):
    def test_comfort_runs_at_21(self):
        v = heat_pump("19.2", "20")
        self.assertEqual((v["want"], v["setpoint"]), ("heat", 21))

    def test_eco_mild_weather_setpoint_19(self):
        v = heat_pump("18.8", "19")
        self.assertEqual((v["want"], v["setpoint"]), ("off", 19))

    def test_eco_cold_weather_setpoint_21(self):
        self.assertEqual(heat_pump("18.8", "19", outdoor="2")["setpoint"], 21)

    def test_turns_on_below_target_minus_half(self):
        self.assertEqual(heat_pump("18.3", "19")["want"], "heat")

    def test_runs_until_21(self):
        self.assertEqual(heat_pump("20.8", "20", current="heat")["want"], "heat")
        self.assertEqual(heat_pump("21.2", "20", current="heat")["want"], "off")

    def test_boost_runs_until_21_5(self):
        self.assertEqual(heat_pump("21.2", "21", current="heat", boost="on")["want"], "heat")

    def test_off_during_hilo_reduction(self):
        self.assertEqual(heat_pump("19.0", "20", defi="reduction")["want"], "off")

    def test_holds_when_temperature_unknown(self):
        self.assertEqual(heat_pump("unavailable", "20", current="heat")["want"], "heat")

    def test_resends_on_start(self):
        self.assertTrue(heat_pump("19.0", "20", trigger_id="start")["resend"])
```

- [ ] **Step 2: Run to verify they fail**

```bash
nix build .#checks.x86_64-linux.heating-policy-test -L
```

Expected: FAIL. The old variables read `now().hour` and fixed thresholds, e.g. `test_comfort_runs_at_21` gets `want == 'off'` at a 19.2 room, or `KeyError` on `want`'s missing inputs.

- [ ] **Step 3: Implement**

Replace the whole `Heating - Heat pump` automation attrset in `"automation heating"` with:

```nix
      {
        alias = "Heating - Heat pump";
        description = "Run the heat pump below the living area's target - 0.5°C until it passes 21°C (21.5 when boosted); setpoint 21 whenever the target is 20 or more or it is below 5°C outside, else 19";
        triggers = [
          {
            trigger = "homeassistant";
            event = "start";
            id = "start";
          }
          {
            trigger = "time_pattern";
            minutes = "/5";
          }
          {
            trigger = "state";
            entity_id = ["sensor.defi_hilo" "sensor.living_area_temperature" living];
          }
        ];
        # HA renders these in order and Nix sorts attribute names, so each
        # may only use variables that sort before it.
        variables = {
          current = "{{ states('climate.living_room_heat_pump') }}";
          # IR is one-way, so the unit can disagree with the state HA
          # restored; on start, send the wanted state even if HA thinks the
          # unit is already there.
          resend = "{{ trigger.id == 'start' }}";
          setpoint = "{{ 21 if states('${living}') | float(0) >= 20 or states('sensor.outdoor_weather_hilo') | float(99) < 5 else 19 }}";
          want = ''
            {%- set temp = states('sensor.living_area_temperature') | float(none) %}
            {%- set target = states('${living}') | float(none) %}
            {%- set high = 21.5 if is_state('${tpl.boostEntity "living_area"}', 'on') else 21 %}
            {%- if ${tpl.hiloReduction} %}off
            {%- elif temp is none or target is none %}{{ current }}
            {%- elif temp < target - 0.5 %}heat
            {%- elif temp > high %}off
            {%- else %}{{ current }}
            {%- endif %}
          '';
        };
        # actions, mode and max_exceeded: keep the existing ones verbatim
        # (the 60 s resend delay and the heat/off `choose`).
      }
```

Keep the existing `actions`, `mode = "single";` and `max_exceeded = "silent";` exactly as they are; they read `want`, `resend`, `current` and `setpoint`, which keep their names.

- [ ] **Step 4: Run the tests**

```bash
nix build .#checks.x86_64-linux.heating-policy-test -L
```

Expected: all pass.

- [ ] **Step 5: Build, format, commit**

```bash
nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link
nix develop -c alejandra hosts/galactica/services/home-assistant-heating
git add hosts/galactica/services/home-assistant-heating
git commit -m "feat(galactica): drive the heat pump from the living area's dynamic target"
```

---

### Task 5: Baseboards follow their zone targets; midnight clears boosts; final module layout

**Files:**
- Modify: `hosts/galactica/services/home-assistant-heating/default.nix` (header comment, `let` block, `Heating - Baseboards`, new `Heating - Clear boosts`)
- Test: `hosts/galactica/services/home-assistant-heating/test_heating.py`

**Interfaces:**
- Consumes: `zones`, `tpl`, `livingBaseboards`, `boostHelpers`.
- Produces: `baseboards`, an attrset from target sensor to the list of climate entity_ids. Automation `Heating - Baseboards` with triggers id `change` (state of every target sensor) and id `morning` (06:00), conditions `[hilo, change-filter]`, and variable `pairs` (a list of `[climate, target]`). Automation `Heating - Clear boosts`.

- [ ] **Step 1: Write the failing tests**

Append to `test_heating.py`:

```python
ALL_BASEBOARDS = {
    "climate.master_bedroom", "climate.amanda_bedroom", "climate.beas_bedroom", "climate.bathroom",
    "climate.office", "climate.bathroom_downstairs", "climate.living_room_2", "climate.living_room_1",
    "climate.dining_room", "climate.workshop_1", "climate.workshop_2", "climate.garage",
}


class Baseboards(unittest.TestCase):
    ALIAS = "Heating - Baseboards"

    def test_target_change_sets_only_that_zone(self):
        hass = Hass(at(MONDAY, "06:30"), {OFFICE: "21"})
        trigger = {"id": "change", "entity_id": OFFICE}
        self.assertEqual(render_variables(hass, self.ALIAS, trigger)["pairs"], [["climate.office", "21"]])

    def test_morning_sets_every_baseboard_once(self):
        pairs = render_variables(Hass(at(MONDAY, "06:00")), self.ALIAS, {"id": "morning"})["pairs"]
        devices = [d for d, _ in pairs]
        self.assertEqual(len(devices), len(set(devices)))
        self.assertEqual(set(devices), ALL_BASEBOARDS)

    def test_ignores_attribute_only_changes(self):
        condition = automation(self.ALIAS)["conditions"][1]["value_template"]
        hass = Hass(at(MONDAY, "06:30"))
        same = {"id": "change", "from_state": SimpleNamespace(state="21"), "to_state": SimpleNamespace(state="21")}
        moved = {"id": "change", "from_state": SimpleNamespace(state="16"), "to_state": SimpleNamespace(state="21")}
        self.assertFalse(hass.render(condition, trigger=same))
        self.assertTrue(hass.render(condition, trigger=moved))
        self.assertTrue(hass.render(condition, trigger={"id": "morning"}))

    def test_stands_down_for_hilo(self):
        condition = automation(self.ALIAS)["conditions"][0]["value_template"]
        self.assertFalse(Hass(at(MONDAY, "06:30"), {"sensor.defi_hilo": "pre_heat"}).render(condition))
        self.assertTrue(Hass(at(MONDAY, "06:30"), {"sensor.defi_hilo": "off"}).render(condition))


class ClearBoosts(unittest.TestCase):
    def test_midnight_clears_all_three(self):
        a = automation("Heating - Clear boosts")
        self.assertEqual(a["triggers"], [{"trigger": "time", "at": "00:00:00"}])
        self.assertEqual(
            set(a["actions"][0]["target"]["entity_id"]),
            {f"input_boolean.heating_boost_{h}" for h in ("living_area", "bedrooms", "office")},
        )
```

- [ ] **Step 2: Run to verify they fail**

```bash
nix build .#checks.x86_64-linux.heating-policy-test -L
```

Expected: FAIL. `pairs` is missing (the old automation has `rooms`/`targets`), and `Heating - Clear boosts` raises `KeyError`.

- [ ] **Step 3: Replace the header comment and `let` block**

Replace everything from the top of `default.nix` through the `in {` line with:

```nix
# House heating, scheduled from Home Assistant rather than the Hilo app.
# Design: docs/superpowers/specs/2026-10-28-dynamic-heating-design.md
#
#   policy     zones.nix: each zone's weekly windows, base, boost, presence
#              gating and warm-up rate. Change a schedule there.
#   sensors    sensor.heating_<zone>_target is what each zone wants now (see
#              templates.nix `plan`); its `reason` attribute says why (base,
#              schedule, preheat, boost, away) and `start` when the next
#              pre-heat begins. sensor.living_area_temperature is the median
#              of the IR hub and the two Hilo thermostats under the heat pump;
#              the hub alone reads 1-1.5°C warm. binary_sensor.living_area_
#              shortfall and _needs_backup bring in the living/dining
#              baseboards through sensor.heating_living_baseboards_target.
#   actuators  one automation for the heat pump, one for every baseboard.
#              The heat pump is HA's alone: it re-evaluates on a timer and on
#              HA start, so a missed edge or a restart corrects itself. A
#              baseboard is set when its zone's target changes and every
#              morning at 06:00; between those it is left to whoever turns
#              the dial or uses the Hilo app, and a restart sets nothing.
#
# Pre-heat starts (target - temp) / rate before a window; a zone that owns a
# rate helper learns it from its own unassisted pre-heats. The heat pump
# (Kanion, IR-only) heats the living and dining rooms and, through them, the
# bedrooms, so it runs long: on below the target - 0.5, off only above 21.
# Its own thermostat reads far colder than the room, so it is driven from
# the living area sensor. Its setpoint is 21 whenever the target is 20 or
# more or it is below 5°C outside: it never gets the room to 21, and 21 is
# how it pushes heat through the house. Otherwise it is 19. On frosty
# mornings it shows "dF" and stops blowing for 5-10 minutes while it
# defrosts; the room drops ~1°C and recovers, which is why the backup waits
# 30 minutes.
#
# Hilo challenges: Hilo lowers the baseboards itself, so the baseboard
# automation stands down from pre_heat through recovery, and the heat pump is
# turned off during the reduction. Boosts (cleared at midnight) do not
# override a challenge.
{lib, ...}: let
  tpl = import ./templates.nix {inherit lib;};
  pretty = lib.replaceStrings ["_"] [" "];

  zoneDefaults = {
    temperature = null;
    weekday = [];
    weekend = [];
    boost = null;
    presence = false;
    rate = null;
    devices = [];
    assist = null;
  };
  zones = lib.mapAttrs (_: z: zoneDefaults // z) (import ./zones.nix);

  # A zone learns the rate helper named after it; others only borrow one.
  learning = lib.filterAttrs (name: z: z.rate != null && z.rate.helper == name) zones;
  boostHelpers = lib.unique (lib.concatMap (z: lib.optional (z.boost != null) z.boost.helper) (lib.attrValues zones));

  living = tpl.targetEntity "living_area";
  livingBaseboards = tpl.targetEntity "living_baseboards";
  targetAttributes = ["reason" "window" "minutes" "start" "since" "from_temp" "assisted" "reached"];

  # Last-resort floor for the living/dining baseboards: 17 at night, 18 by day.
  backupFloor = "(17 if state_attr('${living}', 'reason') == 'base' else 18)";

  # Every target sensor that drives baseboards, and the baseboards it drives.
  baseboards =
    lib.mapAttrs' (name: z: lib.nameValuePair (tpl.targetEntity name) z.devices)
    (lib.filterAttrs (_: z: z.devices != []) zones)
    // {${livingBaseboards} = ["climate.living_room_1" "climate.dining_room"];};

  livingAreaSensors = [
    "sensor.living_room_ir_temperature_2"
    "sensor.living_room_1_temperature"
    "sensor.dining_room_temperature"
  ];
  livingAreaReadings = "${builtins.toJSON livingAreaSensors} | map('states') | select('is_number') | map('float') | list";
in {
```

This drops the old `hiloActive`, `hiloReduction`, `night`, `backupTarget`, `dayNight`, `backupRooms`, the old `baseboards`, `switchHours`, `climates`, `roomsAt` and `roomsByTrigger`. Replace the uses of the old Hilo bindings with `tpl.hiloActive` / `tpl.hiloReduction`; after Task 4, the heat pump's `want` already uses `tpl.hiloReduction`.

- [ ] **Step 4: Replace the baseboards automation and add Clear boosts**

Replace the whole `Heating - Baseboards` attrset with these two:

```nix
      {
        alias = "Heating - Baseboards";
        description = "Set each zone's baseboards when its target changes, and all of them at 06:00, unless a Hilo challenge is running";
        triggers = [
          {
            trigger = "state";
            entity_id = lib.attrNames baseboards;
            not_from = ["unknown" "unavailable"];
            not_to = ["unknown" "unavailable"];
            id = "change";
          }
          {
            # Re-assert every zone daily, so a dial turned by hand lasts at
            # most until morning and a changed zones.nix applies by then.
            trigger = "time";
            at = "06:00:00";
            id = "morning";
          }
        ];
        conditions = [
          {
            condition = "template";
            value_template = "{{ not (${tpl.hiloActive}) }}";
          }
          {
            # A state trigger also fires on attribute changes (pre-heat
            # minutes tick every minute); only a new target counts.
            condition = "template";
            value_template = "{{ trigger.id == 'morning' or trigger.from_state.state != trigger.to_state.state }}";
          }
        ];
        variables.pairs = ''
          {%- set ns = namespace(pairs=[]) %}
          {%- for sensor, climates in (${builtins.toJSON baseboards}).items() if trigger.id == 'morning' or sensor == trigger.entity_id %}
            {%- for climate in climates %}
              {%- set ns.pairs = ns.pairs + [[climate, states(sensor)]] %}
            {%- endfor %}
          {%- endfor %}
          {{ ns.pairs }}
        '';
        actions = [
          {
            repeat = {
              for_each = "{{ pairs }}";
              sequence = [
                {
                  "if" = [
                    {
                      condition = "template";
                      value_template = "{{ states(repeat.item[0]) not in ['unavailable', 'unknown'] and repeat.item[1] is is_number and state_attr(repeat.item[0], 'temperature') | float(0) != repeat.item[1] | float }}";
                    }
                  ];
                  "then" = [
                    {
                      action = "climate.set_temperature";
                      target.entity_id = "{{ repeat.item[0] }}";
                      data.temperature = "{{ repeat.item[1] }}";
                    }
                  ];
                }
              ];
            };
          }
        ];
        mode = "queued";
      }
      {
        alias = "Heating - Clear boosts";
        description = "Turn every heating boost off at midnight, so none is forgotten on";
        triggers = [
          {
            trigger = "time";
            at = "00:00:00";
          }
        ];
        actions = [
          {
            action = "input_boolean.turn_off";
            target.entity_id = map tpl.boostEntity boostHelpers;
          }
        ];
        mode = "single";
      }
```

`mode = "queued"` matters here: several zones can change in the same minute (e.g. 17:00), and `single` would drop all but the first.

- [ ] **Step 5: Run the tests**

```bash
nix build .#checks.x86_64-linux.heating-policy-test -L
```

Expected: all pass. If `test_morning_sets_every_baseboard_once` fails, compare its set against `zones.nix` `devices` plus `living_room_1`/`dining_room`.

- [ ] **Step 6: Build, format, commit**

```bash
nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link
nix develop -c alejandra hosts/galactica/services/home-assistant-heating
git add hosts/galactica/services/home-assistant-heating
git commit -m "feat(galactica): set baseboards when their zone target changes; clear boosts at midnight"
```

---

### Task 6: Learn each zone's warm-up rate

**Files:**
- Modify: `hosts/galactica/services/home-assistant-heating/default.nix`
- Test: `hosts/galactica/services/home-assistant-heating/test_heating.py`

**Interfaces:**
- Consumes: `learning`, `tpl.rate`, `tpl.rateEntity`, `tpl.targetEntity`, `tpl.hiloActive`, `pretty`.
- Produces: automations `Heating - Learn <pretty zone> warm-up rate` for `living_area`, `office` and `family_room`. Each has one template trigger, a single template condition `conditions[0]`, and one `input_number.set_value` action whose `data.value` is a template.

- [ ] **Step 1: Write the failing tests**

Append to `test_heating.py`:

```python
class Learning(unittest.TestCase):
    ALIAS = "Heating - Learn office warm-up rate"
    REACHED = {
        "reason": "preheat",
        "since": at(MONDAY, "06:30").timestamp(),
        "from_temp": 18.0,
        "assisted": False,
        "reached": True,
    }

    def render(self, now, temp="20.0", attrs=None, setpoint=21.0, rate="0"):
        hass = Hass(now, {
            "sensor.office_temperature": temp,
            OFFICE: ("21", {**self.REACHED, **(attrs or {})}),
            "climate.office": ("heat", {"temperature": setpoint}),
            "input_number.heating_rate_office": rate,
            "sensor.defi_hilo": "off",
        })
        a = automation(self.ALIAS)
        return (
            hass.render(a["triggers"][0]["value_template"]),
            hass.render(a["conditions"][0]["value_template"]),
            hass.render(a["actions"][0]["data"]["value"]),
        )

    def test_learns_a_moving_average(self):
        # 2 °C in 1 h, against the 1.5 seed: 0.7 * 1.5 + 0.3 * 2 = 1.65
        self.assertEqual(self.render(at(MONDAY, "07:30")), (True, True, 1.65))

    def test_skips_short_runs(self):
        self.assertFalse(self.render(at(MONDAY, "06:40"))[1])

    def test_skips_assisted_runs(self):
        self.assertFalse(self.render(at(MONDAY, "07:30"), attrs={"assisted": True})[1])

    def test_skips_a_dial_turned_by_hand(self):
        self.assertFalse(self.render(at(MONDAY, "07:30"), setpoint=19.0)[1])

    def test_clamps(self):
        self.assertEqual(self.render(at(MONDAY, "07:30"), temp="30.0", rate="3")[2], 3)

    def test_only_rate_owners_learn(self):
        from harness import CONFIG
        learners = {a["alias"] for a in CONFIG["automation"] if a["alias"].startswith("Heating - Learn")}
        self.assertEqual(learners, {
            "Heating - Learn living area warm-up rate",
            "Heating - Learn office warm-up rate",
            "Heating - Learn family room warm-up rate",
        })
```

- [ ] **Step 2: Run to verify they fail**

```bash
nix build .#checks.x86_64-linux.heating-policy-test -L
```

Expected: FAIL with `KeyError: "no automation 'Heating - Learn office warm-up rate'"`.

- [ ] **Step 3: Implement**

Add to the `let` block of `default.nix`:

```nix
  # After an unassisted pre-heat reaches its target, fold the rate it
  # achieved into the zone's helper (30% new), clamped to 0.2-3 °C/h. Runs
  # under 15 minutes, helped by the shortfall baseboards, during a Hilo
  # challenge, or with a baseboard dial moved off the target are not learned
  # from; a boost or presence change ends the pre-heat before it gets here.
  learn = name: z: let
    sensor = tpl.targetEntity name;
    sameSetpoint = lib.concatMapStrings (d: " and state_attr('${d}', 'temperature') | float(0) == states('${sensor}') | float(0)") z.devices;
  in {
    alias = "Heating - Learn ${pretty name} warm-up rate";
    description = "Learn how fast pre-heat warms the ${pretty name}";
    triggers = [
      {
        trigger = "template";
        value_template = "{{ state_attr('${sensor}', 'reason') == 'preheat' and state_attr('${sensor}', 'reached') == true }}";
      }
    ];
    conditions = [
      {
        condition = "template";
        value_template = ''
          {%- set since = state_attr('${sensor}', 'since') | float(none) %}
          {%- set start = state_attr('${sensor}', 'from_temp') | float(none) %}
          {%- set temp = states('${z.temperature}') | float(none) %}
          {{ since is not none and start is not none and temp is not none
             and now().timestamp() - since >= 900 and temp > start
             and not state_attr('${sensor}', 'assisted')
             and not (${tpl.hiloActive})${sameSetpoint} }}
        '';
      }
    ];
    actions = [
      {
        action = "input_number.set_value";
        target.entity_id = tpl.rateEntity name;
        data.value = ''
          {%- set hours = (now().timestamp() - state_attr('${sensor}', 'since') | float) / 3600 %}
          {%- set observed = (states('${z.temperature}') | float - state_attr('${sensor}', 'from_temp') | float) / hours %}
          {{ ([[0.7 * ${tpl.rate z} + 0.3 * observed, 3] | min, 0.2] | max) | round(2) }}
        '';
      }
    ];
    mode = "single";
  };
```

Make the automation list `[ …heat pump…, …baseboards…, …clear boosts… ] ++ lib.mapAttrsToList learn learning`.

- [ ] **Step 4: Run the tests**

```bash
nix build .#checks.x86_64-linux.heating-policy-test -L
```

Expected: all pass.

- [ ] **Step 5: Build, format, commit**

```bash
nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link
nix develop -c alejandra hosts/galactica/services/home-assistant-heating
git add hosts/galactica/services/home-assistant-heating
git commit -m "feat(galactica): learn each heating zone's warm-up rate from its pre-heats"
```

---

### Task 7: Bring the spec in line with what was built

**Files:**
- Modify: `docs/superpowers/specs/2026-10-28-dynamic-heating-design.md`

- [ ] **Step 1: Apply these amendments**

1. **Architecture → Sensors:** the pre-heat start is the `start` attribute of `sensor.heating_<zone>_target`, not a separate `sensor.heating_<zone>_preheat_start`. Reasons are `base`, `schedule`, `preheat`, `boost`, `away`. Hilo is not folded into the target: the actuators stand down exactly as before.
2. **Architecture → Actuators:** baseboards are also re-asserted for every zone at 06:00, so a hand-turned dial lasts until the next target change or the next morning, and a `zones.nix` change applies by then.
3. **Dynamic pre-heat:** the downstairs bathroom computes its own start using the office's learned rate (only the office learns it).
4. **Verification step 2:** replace the replay script with the `heating-policy-test` flake check, which renders the generated templates with a harness (`hosts/galactica/services/home-assistant-heating/harness.py`).
5. **Heat pump:** it turns on below target − 0.5, so 17.5 at night (previously 18).

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-10-28-dynamic-heating-design.md
git commit -m "docs(galactica): align the dynamic heating spec with the implementation"
```

---

### Task 8: Deploy, add the dashboard controls, verify live

**Files:** none in the repo. This task changes galactica's state: the deploy and HA's dashboard storage.

- [ ] **Step 1: Full checks, push, deploy**

```bash
nix build .#checks.x86_64-linux.heating-policy-test .#nixosConfigurations.galactica.config.system.build.toplevel --no-link -L
git push origin master
just deploy galactica
```

Expected: deploy succeeds; `home-assistant.service` restarts.

- [ ] **Step 2: Check the new entities exist with the expected IDs and no template errors**

```bash
ssh galactica 'nix shell nixpkgs#sqlite -c sudo sqlite3 -readonly /var/lib/hass/home-assistant_v2.db' <<'EOF'
.mode tabs
select sm.entity_id, s.state, json_extract(a.shared_attrs, '$.reason'), json_extract(a.shared_attrs, '$.start')
from states s join states_meta sm on sm.metadata_id = s.metadata_id
left join state_attributes a on a.attributes_id = s.attributes_id
where s.state_id in (select max(state_id) from states group by metadata_id)
  and (sm.entity_id like 'sensor.heating_%' or sm.entity_id like 'input_%heating%'
       or sm.entity_id in ('binary_sensor.alexandre_away', 'binary_sensor.living_area_shortfall', 'binary_sensor.living_area_needs_backup'))
order by 1;
EOF
ssh galactica 'sudo journalctl -u home-assistant --since "-10 min" --no-pager' | grep -iE "template|heating|jinja" | grep -iE "error|warn" || echo "no template errors"
```

Expected: 7 `sensor.heating_*_target` rows (living_area, bedrooms, bathroom, office, bathroom_downstairs, family_room, unheated) plus `sensor.heating_living_baseboards_target`, each with a numeric state and a `reason` matching the current time. Also 3 `input_boolean.heating_boost_*` (off), 3 `input_number.heating_rate_*` (0, which means seeds are in use), and the three binary sensors. The log should show no template errors. If an entity ID differs (e.g. a `_2` suffix from a leftover registry entry), remove the stale entry in Settings → Entities and restart HA.

- [ ] **Step 3: Add the boost buttons and targets to the dashboard**

The dashboards are UI-managed storage; edit them with HA stopped and keep a backup:

```bash
ssh galactica 'sudo systemctl stop home-assistant && sudo cp /var/lib/hass/.storage/lovelace.dashboard_home /var/lib/hass/.storage/lovelace.dashboard_home.bak-20261028'
ssh galactica 'sudo python3 -' <<'EOF'
import json
path = "/var/lib/hass/.storage/lovelace.dashboard_home"
with open(path) as f:
    doc = json.load(f)
views = {v["path"]: v for v in doc["data"]["config"]["views"]}
boosts = [
    {"type": "tile", "entity": f"input_boolean.heating_boost_{h}", "tap_action": {"action": "toggle"}, "icon_tap_action": {"action": "toggle"}}
    for h in ("living_area", "bedrooms", "office")
]
targets = [
    {"type": "tile", "entity": f"sensor.heating_{z}_target"}
    for z in ("living_area", "bedrooms", "bathroom", "office", "bathroom_downstairs", "family_room")
]
section = {"type": "grid", "cards": [{"type": "heading", "heading": "Boosts"}, *boosts, {"type": "heading", "heading": "Targets"}, *targets]}
heating = views["heating"]["sections"]
heating[:] = [s for s in heating if not any(c.get("heading") == "Boosts" for c in s.get("cards", []))]
heating.insert(1, section)
for s in views["home"]["sections"]:
    cards = s.get("cards", [])
    if any(c.get("heading") == "Climate" for c in cards):
        have = {c.get("entity") for c in cards}
        cards.extend(b for b in boosts if b["entity"] not in have)
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
print("ok")
EOF
ssh galactica 'sudo systemctl start home-assistant'
```

Expected: `ok`. The Heating view gets a Boosts/Targets section, and the Home view's Climate card gets the three boost tiles.

- [ ] **Step 4: Smoke-test a boost**

Toggle **Boost bedrooms** on the dashboard. Within a minute, `sensor.heating_bedrooms_target` should read 20 with `reason: boost`, and `climate.master_bedroom` should show setpoint 20. Toggle it off: target 18, and the baseboards go back to 18.

- [ ] **Step 5: Report**

Tell the user:
- what was deployed;
- each zone's current target and reason;
- that baseboards adopt the new targets at their next target change or 06:00 (the deploy restart deliberately sets nothing), so the office stays at its current dial until then unless boosted;
- to check in a week, re-running the per-room kWh / window-temperature analysis against the spec's baseline table.
