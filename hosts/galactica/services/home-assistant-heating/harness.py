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
