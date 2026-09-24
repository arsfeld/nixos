import math
import unittest

from fan_control import DOWN_HOLD, FAN2_CURVE, Curve, Ema, Governor


def gov(current=25):
    return Governor(Curve(FAN2_CURVE), current)


class CurveTest(unittest.TestCase):
    def test_clamps_below_first_point(self):
        self.assertEqual(Curve(FAN2_CURVE)(30), 25)

    def test_clamps_above_last_point(self):
        self.assertEqual(Curve(FAN2_CURVE)(99), 100)

    def test_interpolates_between_points(self):
        self.assertAlmostEqual(Curve(FAN2_CURVE)(70), 42.5)

    def test_hits_points_exactly(self):
        self.assertEqual(Curve(FAN2_CURVE)(85), 75)

    def test_floor_is_first_duty(self):
        self.assertEqual(Curve(FAN2_CURVE).floor, 25)


class EmaTest(unittest.TestCase):
    def test_first_sample_seeds(self):
        self.assertEqual(Ema(60).update(40, 2), 40)

    def test_reaches_63_percent_after_one_time_constant(self):
        ema = Ema(60)
        ema.update(0, 2)
        for _ in range(30):
            value = ema.update(100, 2)
        self.assertAlmostEqual(value, 100 * (1 - math.exp(-1)))


class GovernorTest(unittest.TestCase):
    def test_holds_at_target(self):
        self.assertIsNone(gov(25).step(40, 40, 0))

    def test_deadband_holds_small_rise(self):
        self.assertIsNone(gov(25).step(57, 57, 0))  # target 27

    def test_rise_is_immediate_and_rate_limited(self):
        self.assertEqual(gov(25).step(75, 75, 0), 30)  # target 50

    def test_rise_smaller_than_step_goes_straight_to_target(self):
        self.assertEqual(gov(25).step(58, 58, 0), 28)

    def test_fall_waits_for_hold(self):
        g = gov(50)
        self.assertIsNone(g.step(40, 40, 0))
        self.assertIsNone(g.step(40, 40, DOWN_HOLD - 2))
        self.assertEqual(g.step(40, 40, DOWN_HOLD), 49)

    def test_fall_timer_resets_when_target_catches_up(self):
        g = gov(50)
        g.step(40, 40, 0)
        self.assertIsNone(g.step(75, 75, 30))  # target 50 == current
        self.assertIsNone(g.step(40, 40, 70))
        self.assertIsNone(g.step(40, 40, 70 + DOWN_HOLD - 2))
        self.assertEqual(g.step(40, 40, 70 + DOWN_HOLD), 49)

    def test_ramp_down_continues_one_per_tick(self):
        g = gov(50)
        g.step(40, 40, 0)
        g.commit(g.step(40, 40, DOWN_HOLD))
        self.assertEqual(g.step(40, 40, DOWN_HOLD + 2), 48)

    def test_floor_reachable_through_deadband(self):
        g = gov(27)
        g.step(40, 40, 0)
        g.commit(g.step(40, 40, DOWN_HOLD))
        self.assertEqual(g.current, 26)
        self.assertEqual(g.step(40, 40, DOWN_HOLD + 2), 25)

    def test_deadband_holds_small_fall_above_floor(self):
        g = gov(42)
        g.step(69, 69, 0)  # target 41
        self.assertIsNone(g.step(69, 69, DOWN_HOLD))

    def test_emergency_needs_two_consecutive_ticks(self):
        g = gov(25)
        self.assertIsNone(g.step(40, 96, 0))
        self.assertEqual(g.step(40, 96, 2), 100)
        g.commit(100)
        self.assertIsNone(g.step(40, 97, 4))

    def test_emergency_ticks_must_be_consecutive(self):
        g = gov(25)
        self.assertIsNone(g.step(40, 96, 0))
        self.assertIsNone(g.step(40, 80, 2))
        self.assertIsNone(g.step(40, 96, 4))

    def test_emergency_release_ramps_down_after_hold(self):
        g = gov(25)
        g.step(40, 96, 0)
        g.commit(g.step(40, 96, 2))
        self.assertIsNone(g.step(40, 80, 4))
        self.assertEqual(g.step(40, 80, 4 + DOWN_HOLD), 99)

    def test_short_spike_never_moves_the_fan(self):
        # Recorded on raider 2026-09-24: package 41 -> 71 -> 42 °C in ~10 s.
        ema, g = Ema(60), gov(25)
        trace = [41] * 60 + [52, 60, 71, 71, 64, 44, 42] + [42] * 60
        for i, raw in enumerate(trace):
            self.assertIsNone(g.step(ema.update(raw, 2), raw, i * 2))


if __name__ == "__main__":
    unittest.main()
