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


if __name__ == "__main__":
    unittest.main()
