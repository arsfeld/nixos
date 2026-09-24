# raider Fan Control Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace raider's flapping NZXT H1 V2 fan controller with one driven by
smoothed temperatures, smooth curves and asymmetric rate limits.

**Architecture:** One Python file, `hosts/raider/fan-control/fan_control.py`,
split into pure units (`Ema`, `Curve`, `Governor`) plus thin I/O (`find_temp` /
`read_temp` over sysfs, and `Device` over the `liquidctl` CLI). A loop runs every
2 s and wires them per fan. Unit tests run as the flake check
`raider-fan-control-test`, and the systemd unit in `hosts/raider/fan-control.nix`
runs the file.

**Tech Stack:** Python 3.14 stdlib only, liquidctl CLI, NixOS systemd unit, flake-parts check.

Spec: `docs/superpowers/specs/2026-09-24-raider-fan-control-design.md`.

## Global Constraints

- Tick 2 s.
- fan2 = 140 mm radiator: input coretemp `Package id 0`, EMA τ 60 s,
  curve `(55,25) (65,35) (75,50) (85,75) (92,100)`.
- fan1 = 92 mm GPU exhaust: input amdgpu `edge`, EMA τ 30 s,
  curve `(60,30) (75,40) (85,60) (95,100)`.
- Deadband 3, except exact floor or 100. Up at most +5 per tick, immediately.
  Down only after 60 s continuously below, then −1 per tick.
- Emergency: raw package temp (fan2) or GPU junction temp (fan1) ≥ 95 °C on
  2 consecutive ticks → 100.
- On SIGTERM set both fans to 50%. After 5 consecutive sensor failures set that
  fan to 70%. `liquidctl initialize` failure → exit non-zero. `Restart=always`.
- Stdlib only; no new Nix dependencies.
- The file name uses underscores so the test can import it. This deliberately
  deviates from the spec's `nzxt-fan-control.py`, and the spec is updated in Task 3.
- The success metric counts **ramps** (runs of consecutive same-direction
  commits), not individual writes, because a −1-per-tick ramp-down is many
  writes. The spec is updated in Task 3.

Run tests with: `cd hosts/raider/fan-control && python3 -m unittest -v`

---

### Task 1: Pure control core (`Ema`, `Curve`, `Governor`) and flake check

**Files:**
- Create: `hosts/raider/fan-control/fan_control.py`
- Create: `hosts/raider/fan-control/test_fan_control.py`
- Modify: `flake-modules/checks.nix` (add `raider-fan-control-test` after `immich-pixel-sync-test`)

**Interfaces:**
- Produces:
  - `Ema(tau: float)`, with `.update(sample: float, dt: float) -> float`
  - `Curve(points: list[tuple[float, int]])`, callable `(temp) -> float`, with property `.floor -> int`
  - `Governor(curve: Curve, current: int)`, with:
    - `.step(smoothed: float, emergency: float, now: float) -> int | None`
    - `.commit(duty: int)`
    - `.current: int`
  - Constants: `DEADBAND`, `UP_STEP`, `DOWN_STEP`, `DOWN_HOLD`,
    `EMERGENCY_TEMP`, `EMERGENCY_TICKS`, `FAN2_CURVE`, `FAN1_CURVE`

- [ ] **Step 1: Write the failing tests** in `test_fan_control.py`:

```python
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
```

- [ ] **Step 2: Run the tests to verify they fail.**
  Run `cd hosts/raider/fan-control && python3 -m unittest -v`.
  Expected: `ModuleNotFoundError: No module named 'fan_control'`.

- [ ] **Step 3: Implement** `fan_control.py`:

```python
#!/usr/bin/env python3
"""NZXT H1 V2 fan control for raider.

fan2 (140 mm AIO radiator) follows a slow EMA of the CPU package
temperature, standing in for the coolant temperature the H1 V2 cannot
report. fan1 (92 mm GPU-chamber exhaust) follows the amdgpu edge
temperature. Core temperatures on this CPU jump 20-30 °C within a second,
so nothing here reacts to a raw reading except the emergency override.

Design: docs/superpowers/specs/2026-09-24-raider-fan-control-design.md
"""

import math

FAN2_CURVE = [(55, 25), (65, 35), (75, 50), (85, 75), (92, 100)]
FAN1_CURVE = [(60, 30), (75, 40), (85, 60), (95, 100)]

DEADBAND = 3  # % — ignore smaller target changes, except to reach floor or 100
UP_STEP = 5  # % per tick
DOWN_STEP = 1  # % per tick
DOWN_HOLD = 60.0  # s the target must stay below current before ramping down
EMERGENCY_TEMP = 95.0  # °C raw
EMERGENCY_TICKS = 2


class Ema:
    """Exponential moving average with a time constant in seconds."""

    def __init__(self, tau: float):
        self.tau = tau
        self.value: float | None = None

    def update(self, sample: float, dt: float) -> float:
        if self.value is None:
            self.value = sample
        else:
            self.value += (1 - math.exp(-dt / self.tau)) * (sample - self.value)
        return self.value


class Curve:
    """Piecewise-linear temperature -> duty, clamped at both ends."""

    def __init__(self, points: list[tuple[float, int]]):
        self.points = sorted(points)

    @property
    def floor(self) -> int:
        return self.points[0][1]

    def __call__(self, temp: float) -> float:
        if temp <= self.points[0][0]:
            return self.points[0][1]
        for (t0, d0), (t1, d1) in zip(self.points, self.points[1:]):
            if temp <= t1:
                return d0 + (d1 - d0) * (temp - t0) / (t1 - t0)
        return self.points[-1][1]


class Governor:
    """Decides when a fan's duty actually changes. Pure: no I/O, no clock."""

    def __init__(self, curve: Curve, current: int):
        self.curve = curve
        self.current = current
        self.below_since: float | None = None
        self.hot_ticks = 0

    def step(self, smoothed: float, emergency: float, now: float) -> int | None:
        self.hot_ticks = self.hot_ticks + 1 if emergency >= EMERGENCY_TEMP else 0
        if self.hot_ticks >= EMERGENCY_TICKS:
            self.below_since = None
            return None if self.current == 100 else 100

        target = round(self.curve(smoothed))
        if target >= self.current:
            self.below_since = None
        elif self.below_since is None:
            self.below_since = now

        if target == self.current:
            return None
        if abs(target - self.current) < DEADBAND and target not in (self.curve.floor, 100):
            return None
        if target > self.current:
            return min(target, self.current + UP_STEP)
        if now - self.below_since < DOWN_HOLD:
            return None
        return max(target, self.current - DOWN_STEP)

    def commit(self, duty: int) -> None:
        self.current = duty
```

- [ ] **Step 4: Run the tests to verify they pass.**
  Run the same command. Expected: all tests `OK`.

- [ ] **Step 5: Add the flake check** to `flake-modules/checks.nix`, directly after `immich-pixel-sync-test`:

```nix
        raider-fan-control-test =
          inputs.nixpkgs.legacyPackages.${system}.runCommand "raider-fan-control-test" {
            nativeBuildInputs = [inputs.nixpkgs.legacyPackages.${system}.python3];
          } ''
            cp ${../hosts/raider/fan-control}/*.py .
            python3 -m unittest discover -v -s . -p 'test_*.py'
            touch $out
          '';
```

  Then run:

```bash
git add hosts/raider/fan-control flake-modules/checks.nix
nix build .#checks.x86_64-linux.raider-fan-control-test -L
```

  Expected: builds and prints `OK`.

- [ ] **Step 6: Commit.**
  `just fmt`, then `git commit -m "feat(raider): add smoothed fan governor core"`.

### Task 2: Sensors and device I/O

**Files:**
- Modify: `hosts/raider/fan-control/fan_control.py`
- Modify: `hosts/raider/fan-control/test_fan_control.py`

**Interfaces:**
- Produces:
  - `find_temp(chip: str, label: str, root: str = HWMON_ROOT) -> str`, which raises `LookupError` if not found
  - `read_temp(path: str) -> float | None`
  - `Device(run=subprocess.run)`, with `.initialize() -> bool` and `.set_duty(fan: str, duty: int) -> bool`

- [ ] **Step 1: Write the failing tests.**
  Add `os`, `shutil`, `subprocess` and `tempfile` to the imports, and add
  `Device`, `find_temp` and `read_temp` to the `from fan_control import` line.
  Then add these test classes:

```python
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
```

- [ ] **Step 2: Run the tests.** Expected: `ImportError: cannot import name 'Device'`.

- [ ] **Step 3: Implement.**
  In `fan_control.py`, change `import math` to:

```python
import glob
import logging
import math
import subprocess

log = logging.getLogger("fan-control")
```

  Then append:

```python
HWMON_ROOT = "/sys/class/hwmon"


def _read_text(path: str) -> str | None:
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def find_temp(chip: str, label: str, root: str = HWMON_ROOT) -> str:
    """Path of the tempN_input for `chip`'s sensor labelled `label`.

    hwmon indices are assigned at boot, so resolve by name, never by number.
    """
    for hwmon in sorted(glob.glob(f"{root}/hwmon*")):
        if _read_text(f"{hwmon}/name") != chip:
            continue
        for label_path in sorted(glob.glob(f"{hwmon}/temp*_label")):
            if _read_text(label_path) == label:
                return label_path.removesuffix("_label") + "_input"
    raise LookupError(f"no {chip} temperature labelled {label!r} under {root}")


def read_temp(path: str) -> float | None:
    try:
        return int(_read_text(path)) / 1000
    except (TypeError, ValueError):
        return None


class Device:
    """The H1 V2 through the liquidctl CLI. Fixed duties only: the device has
    no onboard curves and no coolant sensor."""

    def __init__(self, run=subprocess.run):
        self.run = run

    def _liquidctl(self, *args: str) -> bool:
        cmd = ["liquidctl", *args]
        try:
            result = self.run(cmd, capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as e:
            log.error("%s: %s", " ".join(cmd), e)
            return False
        if result.returncode != 0:
            log.error("%s: exit %d: %s", " ".join(cmd), result.returncode, result.stderr.strip())
            return False
        return True

    def initialize(self) -> bool:
        return self._liquidctl("initialize")

    def set_duty(self, fan: str, duty: int) -> bool:
        return self._liquidctl("set", fan, "speed", str(duty))
```

- [ ] **Step 4: Run the tests.** Expected: all `OK`.
- [ ] **Step 5: Commit** with `feat(raider): read fan sensors from sysfs and drive liquidctl`.

### Task 3: Control loop, unit wiring, removal of the old script

**Files:**
- Modify: `hosts/raider/fan-control/fan_control.py`
- Modify: `hosts/raider/fan-control/test_fan_control.py`
- Modify: `hosts/raider/fan-control.nix`
- Delete: `hosts/raider/nzxt-fan-control.py`
- Modify: `docs/superpowers/specs/2026-09-24-raider-fan-control-design.md` (file name; success metric in ramps)

**Interfaces:**
- Consumes everything from Tasks 1 and 2.
- Produces:
  - `Channel` (dataclass)
  - `prime(ch, device) -> bool`
  - `tick(ch, now, dt, device) -> None`
  - `main() -> int`

- [ ] **Step 1: Write the failing tests.**
  Add `FAILSAFE_DUTY`, `Channel`, `prime` and `tick` to the imports, then:

```python
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
```

- [ ] **Step 2: Run the tests.** Expected: `ImportError: cannot import name 'Channel'`.

- [ ] **Step 3: Implement.**
  Extend the imports to:

```python
import glob
import logging
import math
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import date
from typing import Callable
```

  and append:

```python
TICK = 2.0  # s
FAILSAFE_AFTER = 5  # consecutive sensor failures
FAILSAFE_DUTY = 70
EXIT_DUTY = 50  # the device holds its last duty if we die
STATUS_EVERY = 300.0  # s

Reading = tuple[float, float]  # (control signal, emergency signal), °C


@dataclass
class Channel:
    fan: str  # liquidctl channel
    name: str  # signal label for logs
    read: Callable[[], Reading | None]
    ema: Ema
    governor: Governor
    last: Reading | None = None
    failures: int = 0
    commits: int = 0
    ramps: int = 0  # runs of consecutive same-direction commits; the success metric
    last_dir: int = 0
    last_commit: float = -math.inf


def reader(signal_path: str, emergency_path: str) -> Callable[[], Reading | None]:
    def read() -> Reading | None:
        s, e = read_temp(signal_path), read_temp(emergency_path)
        return None if s is None or e is None else (s, e)

    return read


def apply(ch: Channel, duty: int, now: float, device: Device, why: str) -> None:
    previous = ch.governor.current
    if not device.set_duty(ch.fan, duty):
        return  # current unchanged, so the next tick retries
    direction = 1 if duty > previous else -1
    if direction != ch.last_dir or now - ch.last_commit > 1.5 * TICK:
        ch.ramps += 1
    ch.commits += 1
    ch.last_dir, ch.last_commit = direction, now
    ch.governor.commit(duty)
    log.info("%s %d→%d%% (%s)", ch.fan, previous, duty, why)


def prime(ch: Channel, device: Device) -> bool:
    """Set the initial duty from the first reading; the device's own is unknown."""
    reading = ch.read()
    if reading is None:
        duty = FAILSAFE_DUTY
    else:
        ch.last = reading
        duty = round(ch.governor.curve(ch.ema.update(reading[0], TICK)))
    if not device.set_duty(ch.fan, duty):
        return False
    ch.governor.commit(duty)
    log.info("%s start at %d%%", ch.fan, duty)
    return True


def tick(ch: Channel, now: float, dt: float, device: Device) -> None:
    reading = ch.read()
    if reading is None:
        ch.failures += 1
        if ch.failures >= FAILSAFE_AFTER:
            if ch.failures == FAILSAFE_AFTER:
                log.error("%s: %d consecutive sensor failures", ch.fan, ch.failures)
            if ch.governor.current != FAILSAFE_DUTY:
                apply(ch, FAILSAFE_DUTY, now, device, "sensor failsafe")
            return
        if ch.last is None:
            return
        reading = ch.last
    else:
        ch.failures = 0
        ch.last = reading
    raw, emergency = reading
    smoothed = ch.ema.update(raw, dt)
    duty = ch.governor.step(smoothed, emergency, now)
    if duty is not None:
        apply(ch, duty, now, device, f"{ch.name} {smoothed:.1f} °C avg, {raw:.0f} °C raw")


def status(channels: list[Channel]) -> str:
    def avg(ch: Channel) -> str:
        return "no reading" if ch.ema.value is None else f"{ch.ema.value:.1f} °C avg"

    return ", ".join(f"{ch.fan} {ch.governor.current}% ({ch.name} {avg(ch)})" for ch in channels)


def run(channels: list[Channel], device: Device) -> None:
    last = time.monotonic()
    next_status = last + STATUS_EVERY
    day = date.today()
    while True:
        time.sleep(TICK)
        now = time.monotonic()
        dt, last = now - last, now
        for ch in channels:
            tick(ch, now, dt, device)
        if now >= next_status:
            log.info("status: %s", status(channels))
            next_status = now + STATUS_EVERY
        if date.today() != day:
            summary = ", ".join(f"{ch.fan} {ch.ramps} ramps/{ch.commits} writes" for ch in channels)
            log.info("daily %s: %s", day.isoformat(), summary)
            for ch in channels:
                ch.ramps = ch.commits = 0
            day = date.today()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    pkg = find_temp("coretemp", "Package id 0")
    channels = [
        Channel("fan2", "pkg", reader(pkg, pkg), Ema(60), Governor(Curve(FAN2_CURVE), 0)),
        Channel(
            "fan1",
            "gpu",
            reader(find_temp("amdgpu", "edge"), find_temp("amdgpu", "junction")),
            Ema(30),
            Governor(Curve(FAN1_CURVE), 0),
        ),
    ]
    device = Device()
    if not device.initialize():
        return 1
    try:
        for ch in channels:
            if not prime(ch, device):
                return 1
        run(channels, device)
    finally:
        for ch in channels:
            device.set_duty(ch.fan, EXIT_DUTY)
        log.info("exit: fans set to %d%%", EXIT_DUTY)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests.** Expected: all `OK`.

- [ ] **Step 5: Rewire the unit.**
  1. Delete the old script:

     ```bash
     git rm hosts/raider/nzxt-fan-control.py
     ```

  2. Rewrite `hosts/raider/fan-control.nix` with these changes:
     - Header comment: `# NZXT H1 V2 fan control: smoothed curves, see fan-control/fan_control.py`
     - `ExecStart = "${pkgs.python3}/bin/python3 ${./fan-control/fan_control.py}";`
     - `Restart = "always";`
     - `path = [pkgs.liquidctl];`
     - Keep `RestartSec = "10"` and `User = "root"`.
     - Keep `liquidctl` and `lm_sensors` in `environment.systemPackages` for manual use.

- [ ] **Step 6: Update the spec.**
  - Change the file path to `hosts/raider/fan-control/fan_control.py`.
  - Change the success criterion to "under 20 ramps per day (runs of consecutive
    same-direction commits, logged in the `daily` line); zero while idle".

- [ ] **Step 7: Build.**
  Run `just fmt && nix build .#nixosConfigurations.raider.config.system.build.toplevel .#checks.x86_64-linux.raider-fan-control-test`.
  Expected: success.

- [ ] **Step 8: Commit** with `feat(raider): drive NZXT fans from smoothed temperatures`.

### Task 4: Deploy, calibrate, monitor

- [ ] **Step 1: Deploy.**
  Run `just deploy raider`.
  Then check `systemctl status nzxt-fan-control`: it should be active, and the
  journal should show `fan2 start at 25%` and `fan1 start at 30%`.

- [ ] **Step 2: Check idle.**
  Watch `journalctl -u nzxt-fan-control -f` for 10 minutes. Expected: no `→` lines.

- [ ] **Step 3: Calibrate.**
  Run `nix shell nixpkgs#stress-ng -c stress-ng --cpu 16 --timeout 600s`. Record:
  - the plateau of the smoothed package temperature, from the status and commit lines;
  - the fan2 duty it settles at;
  - whether any 100% emergency commit fired.

  If the plateau duty falls outside 75–90%, shift the fan2 points above 65 °C,
  re-run the tests, commit with `fix(raider): calibrate fan2 curve`, and redeploy.

- [ ] **Step 4: Check cool-down.**
  After the stress run, expect a slow −1%/tick ramp starting about 60 s after
  the smoothed temperature falls, ending at 25%.

- [ ] **Step 5: Push.**
  `git push` so `Build & Cache` builds the commit that `weekly-deploy` will see.

- [ ] **Step 6: Check the success metric the next day.**
  The `daily` journal line should show under 20 fan2 ramps.
