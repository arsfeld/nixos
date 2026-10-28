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


if __name__ == "__main__":
    unittest.main()
