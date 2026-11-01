import math
import os
import shutil
import subprocess
import tempfile
import unittest

from fan_control import (
    DOWN_HOLD,
    FAILSAFE_DUTY,
    FAN2_CURVE,
    Channel,
    Curve,
    Device,
    Ema,
    Governor,
    find_temp,
    prime,
    read_temp,
    tick,
)


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


class SysfsTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)

    def hwmon(self, n, chip, temps):
        path = os.path.join(self.root, f"hwmon{n}")
        os.makedirs(path)
        with open(os.path.join(path, "name"), "w") as f:
            f.write(chip + "\n")
        for i, (label, milli) in enumerate(temps, start=1):
            with open(os.path.join(path, f"temp{i}_label"), "w") as f:
                f.write(label + "\n")
            with open(os.path.join(path, f"temp{i}_input"), "w") as f:
                f.write(f"{milli}\n")
        return path

    def test_finds_by_chip_and_label_not_index(self):
        self.hwmon(0, "nvme", [("Composite", 40000)])
        gpu = self.hwmon(3, "amdgpu", [("edge", 55000), ("junction", 61000)])
        self.assertEqual(find_temp("amdgpu", "junction", self.root), os.path.join(gpu, "temp2_input"))

    def test_missing_label_raises(self):
        self.hwmon(0, "coretemp", [("Core 0", 40000)])
        with self.assertRaises(LookupError):
            find_temp("coretemp", "Package id 0", self.root)

    def test_reads_degrees(self):
        path = self.hwmon(0, "coretemp", [("Package id 0", 42500)])
        self.assertEqual(read_temp(os.path.join(path, "temp1_input")), 42.5)

    def test_unreadable_is_none(self):
        self.assertIsNone(read_temp(os.path.join(self.root, "absent")))

    def test_garbage_is_none(self):
        path = os.path.join(self.root, "bad")
        with open(path, "w") as f:
            f.write("n/a\n")
        self.assertIsNone(read_temp(path))


class FakeRun:
    def __init__(self, returncode=0, raises=None):
        self.returncode, self.raises, self.calls = returncode, raises, []

    def __call__(self, cmd, **kwargs):
        self.calls.append(cmd)
        if self.raises:
            raise self.raises
        return subprocess.CompletedProcess(cmd, self.returncode, "", "boom")


class DeviceTest(unittest.TestCase):
    def test_set_duty_invokes_liquidctl(self):
        run = FakeRun()
        self.assertTrue(Device(run).set_duty("fan2", 40))
        self.assertEqual(run.calls, [["liquidctl", "set", "fan2", "speed", "40"]])

    def test_initialize(self):
        run = FakeRun()
        self.assertTrue(Device(run).initialize())
        self.assertEqual(run.calls, [["liquidctl", "initialize"]])

    def test_nonzero_exit_is_failure(self):
        self.assertFalse(Device(FakeRun(returncode=1)).set_duty("fan2", 40))

    def test_timeout_is_failure(self):
        run = FakeRun(raises=subprocess.TimeoutExpired("liquidctl", 10))
        self.assertFalse(Device(run).set_duty("fan2", 40))

    def test_missing_binary_is_failure(self):
        self.assertFalse(Device(FakeRun(raises=FileNotFoundError())).set_duty("fan2", 40))


class FakeDevice:
    def __init__(self, ok=True):
        self.ok, self.calls = ok, []

    def set_duty(self, fan, duty):
        self.calls.append((fan, duty))
        return self.ok


def channel(readings, current=25):
    it = iter(readings)
    return Channel("fan2", "pkg", lambda: next(it), Ema(60), Governor(Curve(FAN2_CURVE), current))


class LoopTest(unittest.TestCase):
    def test_prime_sets_curve_duty(self):
        ch, dev = channel([(75, 75)], current=0), FakeDevice()
        self.assertTrue(prime(ch, dev))
        self.assertEqual((dev.calls, ch.governor.current), ([("fan2", 50)], 50))

    def test_prime_without_reading_uses_failsafe(self):
        ch, dev = channel([None], current=0), FakeDevice()
        self.assertTrue(prime(ch, dev))
        self.assertEqual(dev.calls, [("fan2", FAILSAFE_DUTY)])

    def test_prime_fails_when_write_fails(self):
        self.assertFalse(prime(channel([(40, 40)], current=0), FakeDevice(ok=False)))

    def test_consecutive_commits_are_one_ramp(self):
        ch, dev = channel([(75, 75)] * 3), FakeDevice()
        ch.ema.update(75, 2)
        for i in range(3):
            tick(ch, i * 2.0, 2.0, dev)
        self.assertEqual(dev.calls, [("fan2", 30), ("fan2", 35), ("fan2", 40)])
        self.assertEqual((ch.commits, ch.ramps), (3, 1))

    def test_slow_rise_is_one_ramp_and_reversal_starts_another(self):
        # Under stress on 2026-09-24 a rise committed every 10-110 s.
        ch, dev = channel([(75, 75), (75, 75), (40, 40), (40, 40)]), FakeDevice()
        ch.ema.update(75, 2)
        tick(ch, 0.0, 2.0, dev)
        tick(ch, 110.0, 2.0, dev)
        self.assertEqual(ch.ramps, 1)
        ch.ema.value = 40
        tick(ch, 112.0, 2.0, dev)  # starts the down hold
        tick(ch, 112.0 + DOWN_HOLD, 2.0, dev)
        self.assertEqual((ch.commits, ch.ramps), (3, 2))

    def test_failed_write_keeps_current_and_retries(self):
        ch, dev = channel([(75, 75)] * 2), FakeDevice(ok=False)
        ch.ema.update(75, 2)
        tick(ch, 0.0, 2.0, dev)
        self.assertEqual(ch.governor.current, 25)
        dev.ok = True
        tick(ch, 2.0, 2.0, dev)
        self.assertEqual(ch.governor.current, 30)

    def test_sensor_failures_reuse_last_then_failsafe(self):
        ch, dev = channel([(40, 40)] + [None] * 5), FakeDevice()
        for i in range(5):
            tick(ch, i * 2.0, 2.0, dev)
        self.assertEqual(dev.calls, [])
        tick(ch, 10.0, 2.0, dev)
        self.assertEqual(dev.calls, [("fan2", FAILSAFE_DUTY)])

    def test_recovers_after_failsafe(self):
        ch, dev = channel([None] * 5 + [(40, 40)]), FakeDevice()
        for i in range(6):
            tick(ch, i * 2.0, 2.0, dev)
        self.assertEqual(ch.failures, 0)
        self.assertEqual(ch.governor.current, FAILSAFE_DUTY)  # ramps down after DOWN_HOLD


if __name__ == "__main__":
    unittest.main()
